pragma solidity 0.5.17;

import "./CErc20Delegate.sol";

/**
 * @title Compound's CDai Contract
 * @notice CErc20Delegate with support for depositing somewhere else
 * @author Compound
 */
contract CErc20ExternalYieldDelegate is CErc20Delegate {
    /**
     * @notice External CErc20 contract.
     */
    CErc20 public externalCToken;

    /**
     * @notice Maximum ratio (scaled by 1e18) of this cToken's supply to the external cToken over the total supply to the external cToken.
     * Generally, this should be set to the 1e18 minus the external cToken's utilization at the interest rate model kink (for example, if the IRM kink is at 80% utilization, set this to 0.2e18).
     */
    uint256 public maxExternalCTokenSupplyProportion;

    /**
     * @notice Delegate interface to become the implementation
     * @param data The encoded arguments for becoming
     */
    function _becomeImplementation(bytes calldata data) external {
        require(msg.sender == address(this) || hasAdminRights(), "only self or admin may call _becomeImplementation");

        // Decode data
        (address externalCToken_, uint256 maxExternalCTokenSupplyProportion_) = abi.decode(data, (address, uint256));
        return _becomeImplementation(externalCToken_, maxExternalCTokenSupplyProportion_);
    }

    /**
     * @notice Explicit interface to become the implementation
     * @param externalCTokenAddress_ External cToken to deposit to
     * @param maxExternalCTokenSupplyProportion_ Deposit up to this proportion of the external cToken's total underlying supply
     */
    function _becomeImplementation(address externalCTokenAddress_, uint256 maxExternalCTokenSupplyProportion_) internal {
        // Get external cToken and sanity check the underlying
        CErc20 externalCToken_ = CErc20(externalCTokenAddress_);
        require(externalCToken_.underlying() == underlying, "External cToken underlying must be the same as this cToken's underlying");
        require(maxExternalCTokenSupplyProportion_ <= 1e18, "Max external cToken supply proportion must be <= 1e18.");

        // Remember the relevant data
        externalCToken = externalCToken_;
        maxExternalCTokenSupplyProportion = maxExternalCTokenSupplyProportion_;

        // Approve moving our tokens into the external cToken
        _callOptionalReturn(abi.encodeWithSelector(EIP20NonStandardInterface(underlying).approve.selector, externalCTokenAddress_, uint(-1)), "TOKEN_APPROVAL_FAILED");

        // Transfer cash into external cToken
        rebalanceExternalYield(0);
    }

    /**
     * @notice Delegate interface to resign the implementation
     */
    function _resignImplementation() internal {
        // Redeem all external cTokens
        externalCToken.redeem(uint(-1));
    }

    /*** CToken Overrides ***/

    /**
      * @notice Accrues DSR then applies accrued interest to total borrows and reserves
      * @dev This calculates interest accrued from the last checkpointed block
      *      up to the current block and writes new checkpoint to storage.
      */
    function accrueInterest() public returns (uint) {
        // Accumulate external CToken interest
        externalCToken.accrueInterest();

        // Accumulate this CToken interest
        return super.accrueInterest();
    }

    /*** Safe Token ***/

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @dev This excludes the value of the current message, if any
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view returns (uint) {
        uint256 externalCTokenUnderlyingSupplyBalance = mul_ScalarTruncate(Exp({mantissa: externalCToken.exchangeRateStored()}), externalCToken.balanceOf(address(this)));
        return add_(super.getCashPrior(), externalCTokenUnderlyingSupplyBalance);
    }

    /**
     * @notice Transfer the underlying to this contract and sweep into DSR pot
     * @param from Address to transfer funds from
     * @param amount Amount of underlying to transfer
     * @return The actual amount that is transferred
     */
    function doTransferIn(address from, uint amount) internal returns (uint) {
        // Perform the EIP-20 transfer in
        uint256 realAmount = super.doTransferIn(from, amount);

        // Rebalance (minting/redeeming as necessary)
        rebalanceExternalYield(0);

        // Return amount deposited value returned by super method
        return realAmount;
    }

    /**
     * @notice Transfer the underlying from this contract, after sweeping out of DSR pot
     * @param to Address to transfer funds to
     * @param amount Amount of underlying to transfer
     */
    function doTransferOut(address payable to, uint amount) internal {
        // Rebalance (minting/redeeming as necessary)
        rebalanceExternalYield(amount);

        // Perform the EIP-20 transfer out
        super.doTransferOut(to, amount);
    }

    /**
     * @notice Rebalances unused cash to/from the external cToken
     * @param minCash Minimum amount of cash to be left in this cToken
     */
    function rebalanceExternalYield(uint minCash) internal {
        // Get undeposited cash
        uint256 cash = EIP20Interface(underlying).balanceOf(address(this));

        if (maxExternalCTokenSupplyProportion < 1e18) {
            // No max proportion, so simply withdraw if not enough cash to satisfy `minCash` or deposit if we have extra cash other than `minCash`
            if (cash < minCash) externalCToken.redeemUnderlying(minCash - cash);
            else if (cash > minCash) externalCToken.mint(cash - minCash);
        } else {
            // Get ideal deposit/withdrawal amount
            // (supplyBalance + depositAmount) / (totalSupply + depositAmount) <= maxProportion
            // depositAmount = ((maxProportion * totalSupply) - supplyBalance) / (1 - maxProportion)
            uint256 priorCTokenSupplyBalance = externalCToken.balanceOf(address(this));
            uint256 priorMaxCTokenSupplyBalance = mul_ScalarTruncate(Exp({mantissa: maxExternalCTokenSupplyProportion}), externalCToken.totalSupply());

            if (priorMaxCTokenSupplyBalance > priorCTokenSupplyBalance) {
                // If the ideal is to deposit, but we don't have enough to satisfy minCash, withdraw additional cash needed
                if (cash < minCash) externalCToken.redeemUnderlying(minCash - cash);
                else if (cash > minCash) {
                    // Get maxDepositAmount
                    uint256 maxDepositCTokens = div_(
                        sub_(
                            priorMaxCTokenSupplyBalance,
                            priorCTokenSupplyBalance
                        ),
                        sub_(1e18, maxExternalCTokenSupplyProportion)
                    );
                    uint256 maxDepositAmount = mul_ScalarTruncate(Exp({mantissa: externalCToken.exchangeRateStored()}), maxDepositCTokens);

                    // Deposit max(unusedCash, maxDepositAmount)
                    uint256 unusedCash = cash - minCash;
                    uint256 depositAmount = unusedCash < maxDepositAmount ? unusedCash : maxDepositAmount;
                    if (depositAmount > 0) externalCToken.mint(depositAmount); // TODO: Don't rebalance if small amount?
                }
            } else if (priorMaxCTokenSupplyBalance < priorCTokenSupplyBalance) {
                // Get minWithdrawalAmount
                uint256 minWithdrawalCTokens = div_(
                    sub_(
                        priorCTokenSupplyBalance,
                        priorMaxCTokenSupplyBalance
                    ),
                    sub_(1e18, maxExternalCTokenSupplyProportion)
                );
                uint256 minWithdrawalAmount = mul_ScalarTruncate(Exp({mantissa: externalCToken.exchangeRateStored()}), minWithdrawalCTokens);

                // Withdraw max(additionalCashNeeded, minWithdrawalAmount)
                uint additionalCashNeeded = minCash > cash ? minCash - cash : 0;
                uint withdrawalAmount = additionalCashNeeded > minWithdrawalAmount ? additionalCashNeeded : minWithdrawalAmount;
                if (withdrawalAmount > 0) externalCToken.redeemUnderlying(withdrawalAmount); // TODO: Don't rebalance if small amount?
            }
        }
    }
}
