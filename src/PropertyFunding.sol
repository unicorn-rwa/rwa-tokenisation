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

    // L-3: cap investor count so ROIDistributor.commitDistribution() gas stays bounded.
    // After the H-B rework (sorted O(n) dedup + event-only claimant list) commitDistribution
    // is linear and fits comfortably in a block at this cap (~6M gas @ 2000). Mirrored by
    // ROIDistributor.MAX_CLAIMANTS and PropertyFundingFactory.MAX_INVESTORS — keep in sync.
    // Under the M-B invariant (fundingGoal <= minInvestment * MAX_INVESTORS) the goal is
    // always reached before this many distinct investors can join, so the cap is also an
    // unreachable defense-in-depth backstop — the goal-met transition bounds the count.
    uint256 public constant MAX_INVESTORS = 2000;

    /// @notice Fat-finger guard on the ROI recorded at completion (I-3). Generous — it only
    ///         rejects absurd typos, not legitimate high returns. Not a security boundary;
    ///         the real protection is that finalROIBps is set by a separate Safe (spvAdmin)
    ///         from the one that commits the distribution tree (spvTreasury).
    uint256 public constant MAX_FINAL_ROI_BPS = 100_000; // 1000%

    // ─── Offering document (immutable) ────────────────────────────────────────
    /// @notice Original IPFS CID of the legal offering documents, set at deploy.
    ///         Never changes — protects investors from post-raise manipulation.
    string public offeringDocHash;

    // ─── Mutable state ─────────────────────────────────────────────────────────
    uint256 public totalRaised;
    uint256 public totalRefunded; // L-3: cumulative USDC refunded — tracks outstanding refund liability so sweepStrayUSDC() never touches owed funds
    uint256 public fundedAt; // timestamp when state → FUNDED; 0 until goal is met

    /// @notice Actual realized ROI in basis points, recorded by ADMIN_ROLE at setCompleted()
    ///         (I-3). The ROIDistributor caps every claim at principal * (1 + finalROIBps)
    ///         (+ a small rounding buffer), so a compromised distribution tree cannot pay any
    ///         wallet more than its true entitlement. Set by the operational (spvAdmin) Safe —
    ///         a DIFFERENT Safe than the spvTreasury that commits the tree — so inflating a
    ///         payout would require BOTH Safes to be compromised (separation of duties).
    ///         May legitimately be 0 (principal-only return). 0 until COMPLETED.
    uint256 public finalROIBps;

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
    event StrayFundsSwept(address indexed recipient, uint256 amount);
    event ProjectCompleted(uint256 finalROIBps);

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
    error GoalExceedsCapacity();
    error NothingToSweep();
    error ROITooHigh();

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
        // M-B: goal must be reachable within MAX_INVESTORS at the minimum ticket size.
        //      Guarantees FUNDED is reached before the investor cap, so the cap can never
        //      block a still-unmet raise (eliminates Sybil slot-exhaustion DoS) and keeps
        //      the investor count bounded by construction.
        if (fundingGoal_ > minInvestment_ * MAX_INVESTORS) revert GoalExceedsCapacity();

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
        totalRefunded += amount; // L-3: shrink outstanding refund liability

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
     * @notice Mark project as COMPLETED once construction is done, recording the actual
     *         realized ROI (I-3). The ROIDistributor reads finalROIBps to cap every claim
     *         at the holder's true entitlement, so the distribution flow must be driven only
     *         after this is set. ROIDistributor funding/claims are handled separately.
     * @param finalROIBps_ Actual realized return in basis points (e.g. 1500 = 15%). May be 0
     *                     for a principal-only return. Must be <= MAX_FINAL_ROI_BPS.
     */
    function setCompleted(uint256 finalROIBps_)
        external
        onlyRole(ADMIN_ROLE)
        onlyState(State.ACTIVE)
    {
        if (finalROIBps_ > MAX_FINAL_ROI_BPS) revert ROITooHigh();
        finalROIBps = finalROIBps_;
        _transitionTo(State.COMPLETED);
        emit ProjectCompleted(finalROIBps_);
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

    /**
     * @notice Sweep stray USDC (e.g. tokens transferred directly to this contract by
     *         mistake) to the treasury. L-3: only ever moves funds that are NOT owed to
     *         investors — see strayUSDC() for exactly how much that is per state. Reverts
     *         while the raise is still live/awaiting withdrawal (FUNDRAISING/FUNDED), where
     *         every USDC is owed. Sends to withdrawalRecipient (the treasury), same as
     *         withdrawFunds().
     */
    function sweepStrayUSDC() external nonReentrant onlyRole(ADMIN_ROLE) {
        uint256 amount = strayUSDC();
        if (amount == 0) revert NothingToSweep();
        usdc.safeTransfer(withdrawalRecipient, amount);
        emit StrayFundsSwept(withdrawalRecipient, amount);
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

    /**
     * @notice USDC held by this contract that is NOT owed to investors and may be swept
     *         to the treasury via sweepStrayUSDC() (L-3). Returns:
     *           - FUNDRAISING / FUNDED      → 0 (every USDC is owed: refundable or pending
     *                                         withdrawal — sweeping is disallowed here)
     *           - WITHDRAWN/ACTIVE/COMPLETED→ full balance (the tracked principal already
     *                                         left via withdrawFunds; ROI lives in the
     *                                         separate ROIDistributor, so anything here is
     *                                         a stray transfer)
     *           - REFUNDING / REFUNDED      → balance minus the still-unclaimed refund
     *                                         liability (totalRaised - totalRefunded), so
     *                                         every unclaimed refund stays fully funded
     */
    function strayUSDC() public view returns (uint256) {
        uint256 bal = usdc.balanceOf(address(this));
        if (state == State.WITHDRAWN || state == State.ACTIVE || state == State.COMPLETED) {
            return bal;
        }
        if (state == State.REFUNDING || state == State.REFUNDED) {
            uint256 owed = totalRaised - totalRefunded; // refunds not yet claimed
            return bal > owed ? bal - owed : 0;
        }
        return 0; // FUNDRAISING / FUNDED — everything is owed
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
