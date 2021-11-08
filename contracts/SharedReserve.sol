pragma solidity 0.5.16;

import "EIP20Interface.sol";

/**
 * @title CToken shared reserve contract
 * @notice Shared reserves that can be withdrew by governance to provide insurance to users.
 * @author Rari Capital
 */
contract SharedReserve {

    /**
     * @notice Administrator for this contract
     */
    address payable public governance;

    /**
     * @notice Underlying asset for this Shared Reserve
     */
    address underlying;

    /**
     * @notice A boolean indicating whether the underlying asset is ETH
    */
    bool immutable isETH;

    constructor(address _governance, address _underlying, bool _isEth) {
        governance = _governance;
        underlying = _underlying;
        isETH = _isEth;
    }

    function withdraw(uint256 amount) public payable {
        require(msg.sender == governance);

        require(underlying.balanceOf(this) >= amount);
        if(isETH) {
            governance.transfer(amount);
        } else {
            EIP20Interface(underlying).transfer(governance, amount);
        }
    }
}