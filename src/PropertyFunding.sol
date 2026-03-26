// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IKYCRegistry} from "./interfaces/IKYCRegistry.sol";
import {PropertyToken} from "./PropertyToken.sol";

/**
 * @title PropertyFunding
 * @notice Manages one real estate construction project:
 *         - Investors deposit USDC, receive PropertyTokens (1 USDC = 1 token)
 *         - If goal met before deadline → admin withdraws to multisig for fiat conversion
 *         - If deadline passes with goal unmet → investors claim full refunds
 *         - After construction completes → ROIDistributor handles principal + ROI payouts
 *
 * State machine:
 *
 *   FUNDRAISING ──(goal met)──► FUNDED ──(admin withdraws)──► WITHDRAWN
 *        │                                                          │
 *   (deadline passed,                                       (admin setActive)
 *    goal not met)                                                  │
 *        │                                                        ACTIVE
 *        ▼                                                          │
 *    REFUNDING ◄──────────────────────────────────────────── (admin setCompleted)
 *        │                                                          │
 *        ▼                                                       COMPLETED
 *    REFUNDED (informational — set when last refund claimed)
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE — Gnosis Safe
 *   ADMIN_ROLE         — Gnosis Safe; state transitions, fund withdrawal
 *   PAUSER_ROLE        — Gnosis Safe; emergency stop
 */
contract PropertyFunding is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    // ─── Project state ─────────────────────────────────────────────────────────
    enum State {
        FUNDRAISING, // 0 — accepting investments
        FUNDED,      // 1 — goal met, waiting for admin to withdraw
        WITHDRAWN,   // 2 — funds sent to multisig for fiat conversion
        ACTIVE,      // 3 — construction underway
        COMPLETED,   // 4 — project done, ROIDistributor handles payouts
        REFUNDING,   // 5 — deadline passed, goal unmet — investors claim refunds
        REFUNDED     // 6 — all refunds claimed (informational)
    }

    State public state; // starts at FUNDRAISING (0)

    // ─── Immutable project parameters ─────────────────────────────────────────
    IERC20         public immutable usdc;
    PropertyToken  public immutable propertyToken;
    IKYCRegistry   public immutable kycRegistry;
    address        public immutable withdrawalRecipient; // Gnosis Safe multisig
    uint256        public immutable fundingGoal;         // USDC (6 decimals)
    uint256        public immutable deadline;            // unix timestamp
    uint256        public immutable expectedROIBps;      // e.g. 1500 = 15%
    uint256        public immutable estimatedStartDate;
    uint256        public immutable estimatedEndDate;
    uint256        public immutable minInvestment;       // USDC minimum per tx

    // PropertyToken uses 18 decimals, USDC uses 6 → scale by 1e12
    uint256 public constant DECIMALS_FACTOR = 1e12;

    // ─── Mutable state ─────────────────────────────────────────────────────────
    uint256 public totalRaised;
    string  public metadataURI; // IPFS CID — admin can update with new photos/docs

    mapping(address => uint256) public investments; // wallet → total USDC invested
    address[] private _investors;
    mapping(address => bool) private _isInvestor;

    // ─── Events ────────────────────────────────────────────────────────────────
    event Invested(address indexed investor, uint256 usdcAmount, uint256 tokenAmount);
    event RefundClaimed(address indexed investor, uint256 usdcAmount);
    event FundsWithdrawn(address indexed recipient, uint256 usdcAmount);
    event StateChanged(State indexed from, State indexed to);
    event MetadataUpdated(string newURI);

    // ─── Errors ────────────────────────────────────────────────────────────────
    error WrongState(State required, State actual);
    error DeadlinePassed();
    error DeadlineNotReached();
    error GoalAlreadyMet();
    error BelowMinimum(uint256 min, uint256 provided);
    error NotEligibleInvestor(address investor);
    error NothingToRefund();
    error ZeroAddress();
    error InvalidParam();

    // ─── Modifiers ─────────────────────────────────────────────────────────────
    modifier onlyState(State required) {
        if (state != required) revert WrongState(required, state);
        _;
    }

    // ─── Constructor ───────────────────────────────────────────────────────────
    constructor(
        address usdc_,
        address propertyToken_,
        address kycRegistry_,
        address withdrawalRecipient_,
        address admin_,
        uint256 fundingGoal_,
        uint256 deadline_,
        uint256 expectedROIBps_,
        uint256 estimatedStartDate_,
        uint256 estimatedEndDate_,
        uint256 minInvestment_,
        string memory metadataURI_
    ) {
        if (
            usdc_ == address(0) ||
            propertyToken_ == address(0) ||
            kycRegistry_ == address(0) ||
            withdrawalRecipient_ == address(0) ||
            admin_ == address(0)
        ) revert ZeroAddress();

        if (fundingGoal_ == 0 || minInvestment_ == 0 || deadline_ <= block.timestamp)
            revert InvalidParam();

        usdc               = IERC20(usdc_);
        propertyToken      = PropertyToken(propertyToken_);
        kycRegistry        = IKYCRegistry(kycRegistry_);
        withdrawalRecipient = withdrawalRecipient_;
        fundingGoal        = fundingGoal_;
        deadline           = deadline_;
        expectedROIBps     = expectedROIBps_;
        estimatedStartDate = estimatedStartDate_;
        estimatedEndDate   = estimatedEndDate_;
        minInvestment      = minInvestment_;
        metadataURI        = metadataURI_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(PAUSER_ROLE, admin_);
    }

    // ─── Investor actions ──────────────────────────────────────────────────────

    /**
     * @notice Invest USDC into the project.
     *         Requires prior USDC approval: usdc.approve(address(this), amount)
     *         Mints PropertyTokens 1:1 (scaling for decimals applied).
     */
    function invest(uint256 usdcAmount)
        external
        nonReentrant
        whenNotPaused
        onlyState(State.FUNDRAISING)
    {
        if (block.timestamp >= deadline) revert DeadlinePassed();
        if (usdcAmount < minInvestment) revert BelowMinimum(minInvestment, usdcAmount);
        if (!kycRegistry.isEligibleInvestor(msg.sender)) revert NotEligibleInvestor(msg.sender);

        // Effects — update state before external calls (CEI pattern)
        investments[msg.sender] += usdcAmount;
        totalRaised             += usdcAmount;

        if (!_isInvestor[msg.sender]) {
            _investors.push(msg.sender);
            _isInvestor[msg.sender] = true;
        }

        if (totalRaised >= fundingGoal) {
            _transitionTo(State.FUNDED);
        }

        // Interactions — external calls after all state changes
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);

        uint256 tokenAmount = usdcAmount * DECIMALS_FACTOR;
        propertyToken.mint(msg.sender, tokenAmount);

        emit Invested(msg.sender, usdcAmount, tokenAmount);
    }

    /**
     * @notice Claim full USDC refund when project failed to reach its goal.
     *         Burns the investor's PropertyTokens.
     */
    function claimRefund()
        external
        nonReentrant
        onlyState(State.REFUNDING)
    {
        uint256 amount = investments[msg.sender];
        if (amount == 0) revert NothingToRefund();

        // Effects
        investments[msg.sender] = 0;

        // Interactions
        uint256 tokenBalance = propertyToken.balanceOf(msg.sender);
        if (tokenBalance > 0) {
            propertyToken.burn(msg.sender, tokenBalance);
        }
        usdc.safeTransfer(msg.sender, amount);

        emit RefundClaimed(msg.sender, amount);
    }

    // ─── Admin state transitions ───────────────────────────────────────────────

    /**
     * @notice Withdraw raised USDC to the Gnosis Safe multisig.
     *         Admin calls this after the funding goal is confirmed met.
     *         Multisig then converts to fiat via Coinbase Prime.
     */
    function withdrawFunds()
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
        onlyState(State.FUNDED)
    {
        uint256 amount = usdc.balanceOf(address(this));
        _transitionTo(State.WITHDRAWN);
        usdc.safeTransfer(withdrawalRecipient, amount);
        emit FundsWithdrawn(withdrawalRecipient, amount);
    }

    /**
     * @notice Mark project as ACTIVE once fiat conversion is complete
     *         and construction has started.
     */
    function setActive()
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.WITHDRAWN)
    {
        _transitionTo(State.ACTIVE);
    }

    /**
     * @notice Mark project as COMPLETED once construction is done.
     *         ROIDistributor.depositReturns() is called separately.
     */
    function setCompleted()
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.ACTIVE)
    {
        _transitionTo(State.COMPLETED);
    }

    /**
     * @notice Anyone can trigger REFUNDING once the deadline has passed
     *         and the goal was not met. Trustless — no admin required.
     */
    function triggerRefund() external onlyState(State.FUNDRAISING) {
        if (block.timestamp < deadline)  revert DeadlineNotReached();
        if (totalRaised >= fundingGoal)  revert GoalAlreadyMet();
        _transitionTo(State.REFUNDING);
    }

    /// @notice Admin updates IPFS metadata URI (construction photos, legal docs)
    function updateMetadata(string calldata newURI) external onlyRole(ADMIN_ROLE) {
        metadataURI = newURI;
        emit MetadataUpdated(newURI);
    }

    // ─── View helpers ──────────────────────────────────────────────────────────

    function investorCount() external view returns (uint256) {
        return _investors.length;
    }

    function getInvestors() external view returns (address[] memory) {
        return _investors;
    }

    function amountLeftToFund() external view returns (uint256) {
        if (totalRaised >= fundingGoal) return 0;
        return fundingGoal - totalRaised;
    }

    function isDeadlinePassed() external view returns (bool) {
        return block.timestamp >= deadline;
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    function _transitionTo(State newState) internal {
        emit StateChanged(state, newState);
        state = newState;
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
