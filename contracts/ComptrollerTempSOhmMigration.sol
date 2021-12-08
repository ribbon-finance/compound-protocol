pragma solidity ^0.5.16;

import "./CToken.sol";
import "./ComptrollerStorage.sol";
import "./Unitroller.sol";

/**
 * @title Compound's Comptroller Contract
 * @author Compound
 * @dev This contract should not to be deployed alone; instead, deploy `Unitroller` (proxy contract) on top of this `Comptroller` (logic/implementation contract).
 */
contract ComptrollerTempSOhmMigration is ComptrollerV3Storage {
    function _become(Unitroller unitroller) public {
        require((msg.sender == address(fuseAdmin) && unitroller.fuseAdminHasRights()) || (msg.sender == unitroller.admin() && unitroller.adminHasRights()), "only unitroller admin can change brains");

        uint changeStatus = unitroller._acceptImplementation();
        require(changeStatus == 0, "change not authorized");

        ComptrollerTempSOhmMigration(address(unitroller))._becomeImplementation();
    }

    address public constant SOHM_V1 = 0x04F2694C8fcee23e8Fd0dfEA1d4f5Bb8c352111F;
    address public constant GOHM = 0x0ab87046fBb341D058F17CBC4c1133F25a20a52f;

    function _becomeImplementation() external {
        require(msg.sender == comptrollerImplementation, "only implementation may call _becomeImplementation");

        if (address(cTokensByUnderlying[SOHM_V1]) != address(0) && address(cTokensByUnderlying[GOHM]) == address(0)) {
            CToken cToken = cTokensByUnderlying[SOHM_V1];
            cTokensByUnderlying[SOHM_V1] = CToken(address(0));
            cTokensByUnderlying[GOHM] = cToken;
        }
    }
}
