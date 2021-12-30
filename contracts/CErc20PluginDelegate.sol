pragma solidity ^0.5.16;
pragma experimental ABIEncoderV2;

import "./CErc20Delegate.sol";
import "./EIP20Interface.sol";
import "./IPlugin.sol";

/**
 * @title Rari's CErc20Plugin's Contract
 * @notice CToken which outsources token logic to a plugin
 * @author Joey Santoro
 *
 * CErc20PluginDelegate deposits and withdraws from a plugin conract
 * It is also capable of delegating reward functionality to a PluginRewardsDistributor
 */
contract CErc20PluginDelegate is CErc20Delegate {

    /**
     * @notice Plugin address
     */
    IPlugin public plugin;

    uint256 constant public PRECISION = 1e18;
    
    /**
     * @notice Delegate interface to become the implementation
     * @param data The encoded arguments for becoming
     */
    function _becomeImplementation(bytes calldata data) external {
        require(msg.sender == address(this) || hasAdminRights());

        (address _plugin) = abi.decode(
            data,
            (address)
        );

        IPlugin oldPlugin = plugin;
        plugin = IPlugin(_plugin);

        if (address(oldPlugin) != address(0) && address(oldPlugin) != _plugin) {
            oldPlugin.withdraw(address(this), oldPlugin.balanceOfUnderlying(address(this)));
        }

        EIP20Interface(underlying).approve(_plugin, uint256(-1));
        
        plugin.deposit(address(this), EIP20Interface(underlying).balanceOf(address(this)));
    }

    /*** CToken Overrides ***/

    /*** Safe Token ***/

    /**
     * @notice Gets balance of the plugin in terms of the underlying
     * @return The quantity of underlying tokens owned by this contract
     */
    function getCashPrior() internal view returns (uint256) {
        return plugin.balanceOfUnderlying(address(this));
    }

    /**
     * @notice Transfer the underlying to the cToken and trigger a deposit
     * @param from Address to transfer funds from
     * @param amount Amount of underlying to transfer
     * @return The actual amount that is transferred
     */
    function doTransferIn(
        address from,
        uint256 amount
    ) internal returns (uint256) {
        // Perform the EIP-20 transfer in
        require(EIP20Interface(underlying).transferFrom(from, address(this), amount), "send fail");

        plugin.deposit(address(this), amount);
        return amount;
    }

    /**
     * @notice Transfer the underlying from plugin to destination
     * @param to Address to transfer funds to
     * @param amount Amount of underlying to transfer
     */
    function doTransferOut(
        address payable to,
        uint256 amount
    ) internal {
        plugin.withdraw(to, amount);
    }
}