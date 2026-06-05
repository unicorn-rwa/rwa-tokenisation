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
    uint256        public immutable minInvestment;            // USDC minimum per tx
    uint256        public immutable maxAccreditedInvestment;   // Reg D 506(c) cap per investor (default 25_000e6)
    uint256        public immutable maxNonAccreditedUSInvestment; // Reg D 506(b) cap per investor (default 2_500e6)

    // PropertyToken uses 18 decimals, USDC uses 6 → scale by 1e12
    uint256 public constant DECIMALS_FACTOR = 1e12;

    // Maximum allowed fundraising window — prevents indefinite fund-locking
    uint256 public constant MAX_FUNDRAISING_DURATION = 180 days;

    // How long admin has to call withdrawFunds() after goal is met before
    // investors can force a refund (H-1 escape hatch)
    uint256 public constant WITHDRAWAL_TIMEOUT = 30 days;

    // L-3: cap investor count so commitDistribution() gas stays within Base block limits
    // (500 investors ≈ 20.5M gas on commitDistribution — 34% of Base block)
    uint256 public constant MAX_INVESTORS = 500;

    // ─── Offering document (immutable) ────────────────────────────────────────
    /// @notice Original IPFS CID of the legal offering documents, set at deploy.
    ///         Never changes — protects investors from post-raise manipulation.
    string public offeringDocHash;

    // ─── Mutable state ─────────────────────────────────────────────────────────
    uint256 public totalRaised;
    uint256 public fundedAt; // timestamp when state → FUNDED; 0 until goal is met

    /// @notice Append-only update log: construction photos, progress reports, etc.
    ///         Index 0 is the first post-deploy update. Use latestMetadata() for UI.
    string[] private _metadataUpdates;

    mapping(address => uint256) public investments; // wallet → total USDC invested
    address[] private _investors;
    mapping(address => bool) private _isInvestor;

    // ─── Events ────────────────────────────────────────────────────────────────
    event Invested(address indexed investor, uint256 usdcAmount, uint256 tokenAmount);
    event RefundClaimed(address indexed investor, uint256 usdcAmount);
    event FundsWithdrawn(address indexed recipient, uint256 usdcAmount);
    event StateChanged(State indexed from, State indexed to);
    event MetadataUpdatePushed(string cid, uint256 indexed index, uint256 timestamp);

    // ─── Errors ────────────────────────────────────────────────────────────────
    error WrongState(State required, State actual);
    error DeadlinePassed();
    error DeadlineNotReached();
    error DeadlineTooFar();
    error WithdrawalTimeoutNotReached();
    error GoalAlreadyMet();
    error BelowMinimum(uint256 min, uint256 provided);
    error ExceedsInvestorLimit(uint256 limit, uint256 wouldBeTotal);
    error RestrictedCountry(address investor, bytes2 country);
    error NotEligibleInvestor(address investor);
    error NothingToRefund();
    error NotAnInvestor();
    error ZeroAddress();
    error InvalidParam();
    error TooManyInvestors();

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
        uint256 maxAccreditedInvestment_,
        uint256 maxNonAccreditedUSInvestment_,
        string memory offeringDocHash_
    ) {
        if (
            usdc_ == address(0) ||
            propertyToken_ == address(0) ||
            kycRegistry_ == address(0) ||
            withdrawalRecipient_ == address(0) ||
            admin_ == address(0)
        ) revert ZeroAddress();

        if (
            fundingGoal_ == 0 ||
            minInvestment_ == 0 ||
            maxAccreditedInvestment_ == 0 ||
            maxNonAccreditedUSInvestment_ == 0 ||
            deadline_ <= block.timestamp
        ) revert InvalidParam();
        if (deadline_ > block.timestamp + MAX_FUNDRAISING_DURATION) revert DeadlineTooFar();
        // M-3: relational validation — min must not exceed per-investor caps
        if (minInvestment_ > maxAccreditedInvestment_) revert InvalidParam();
        if (minInvestment_ > maxNonAccreditedUSInvestment_) revert InvalidParam();

        usdc                        = IERC20(usdc_);
        propertyToken               = PropertyToken(propertyToken_);
        kycRegistry                 = IKYCRegistry(kycRegistry_);
        withdrawalRecipient         = withdrawalRecipient_;
        fundingGoal                 = fundingGoal_;
        deadline                    = deadline_;
        expectedROIBps              = expectedROIBps_;
        estimatedStartDate          = estimatedStartDate_;
        estimatedEndDate            = estimatedEndDate_;
        minInvestment               = minInvestment_;
        maxAccreditedInvestment     = maxAccreditedInvestment_;
        maxNonAccreditedUSInvestment = maxNonAccreditedUSInvestment_;
        offeringDocHash             = offeringDocHash_;

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

        bytes2 country = kycRegistry.getCountry(msg.sender);
        if (kycRegistry.isCountryRestricted(country)) revert RestrictedCountry(msg.sender, country);

        // Enforce per-investor-type cumulative cap for this property
        // Reg S (non-US) investors have no cap — only US tracks apply
        uint256 newTotal = investments[msg.sender] + usdcAmount;
        if (kycRegistry.isAccredited(msg.sender)) {
            if (newTotal > maxAccreditedInvestment)
                revert ExceedsInvestorLimit(maxAccreditedInvestment, newTotal);
        } else if (kycRegistry.isNonAccreditedUS(msg.sender)) {
            if (newTotal > maxNonAccreditedUSInvestment)
                revert ExceedsInvestorLimit(maxNonAccreditedUSInvestment, newTotal);
        }

        // Effects — update state before external calls (CEI pattern)
        investments[msg.sender] += usdcAmount;
        totalRaised             += usdcAmount;

        if (!_isInvestor[msg.sender]) {
            // L-3: cap investor count — prevents unbounded array growth / distributor gas DoS
            if (_investors.length >= MAX_INVESTORS) revert TooManyInvestors();
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
        // M-4: use totalRaised (tracked amount) not balanceOf — prevents accidentally
        //      sent USDC from being swept to the multisig
        uint256 amount = totalRaised;
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
     * @notice Trustless escape hatch — investors can force REFUNDING in two cases:
     *
     *   1. FUNDRAISING: deadline passed and goal was not met (original path).
     *   2. FUNDED: goal was met but admin failed to call withdrawFunds() within
     *              WITHDRAWAL_TIMEOUT (30 days). USDC is still in this contract,
     *              so a full refund is possible.
     *
     * In both cases no admin action is required — any investor can call this.
     */
    function triggerRefund() external {
        if (investments[msg.sender] == 0) revert NotAnInvestor();

        if (state == State.FUNDRAISING) {
            if (block.timestamp < deadline) revert DeadlineNotReached();
            if (totalRaised >= fundingGoal) revert GoalAlreadyMet();
        } else if (state == State.FUNDED) {
            if (block.timestamp <= fundedAt + WITHDRAWAL_TIMEOUT) revert WithdrawalTimeoutNotReached();
        } else {
            revert WrongState(State.FUNDRAISING, state);
        }

        _transitionTo(State.REFUNDING);
    }

    /// @notice Push a new IPFS CID to the update log (construction photos, progress reports).
    ///         Append-only — existing records cannot be edited or deleted.
    ///         The original offeringDocHash is always preserved separately.
    function pushMetadataUpdate(string calldata cid) external onlyRole(ADMIN_ROLE) {
        _metadataUpdates.push(cid);
        emit MetadataUpdatePushed(cid, _metadataUpdates.length - 1, block.timestamp);
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

    /// @notice Full append-only update history as an array of IPFS CIDs.
    ///         UI can display this as a timeline alongside offeringDocHash.
    function getMetadataHistory() external view returns (string[] memory) {
        return _metadataUpdates;
    }

    /// @notice Latest metadata CID: most recent update, or offeringDocHash if no updates yet.
    function latestMetadata() external view returns (string memory) {
        if (_metadataUpdates.length == 0) return offeringDocHash;
        return _metadataUpdates[_metadataUpdates.length - 1];
    }

    // ─── Internal ──────────────────────────────────────────────────────────────

    function _transitionTo(State newState) internal {
        emit StateChanged(state, newState);
        state = newState;
        if (newState == State.FUNDED) fundedAt = block.timestamp;
    }

    // ─── Emergency ─────────────────────────────────────────────────────────────

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }
}
