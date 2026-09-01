// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.36;

import { IERC1155Queue } from "../interfaces/IERC1155Queue.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC1155 } from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";

/// @title ERC1155Queue
/// @author kexley
/// @notice This contract implements the ERC1155 standard
contract ERC1155Queue is IERC1155Queue, ERC1155, Ownable {
    constructor(string memory _uri) ERC1155(_uri) Ownable(msg.sender) { }

    /// @inheritdoc IERC1155Queue
    function mint(address _to, uint256 _id, uint256 _amount) external onlyOwner {
        _mint(_to, _id, _amount, "");
    }

    /// @inheritdoc IERC1155Queue
    function burn(address _from, uint256 _id, uint256 _amount) external onlyOwner {
        _burn(_from, _id, _amount);
    }
}
