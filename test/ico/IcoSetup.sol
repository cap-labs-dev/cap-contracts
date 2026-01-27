// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import { AccessControl } from "../../contracts/access/AccessControl.sol";
import { CCAToken } from "../../contracts/ico/CCAToken.sol";
import { SoulboundERC721Merkle } from "../../contracts/ico/SoulboundERC721Merkle.sol";
import { ValidationHook } from "../../contracts/ico/ValidationHook.sol";
import { MockPredicateRegistry } from "../mocks/MockPredicateRegistry.sol";
import { MockZapRouter } from "../mocks/MockZapRouter.sol";

import { Test } from "forge-std/Test.sol";

contract IcoSetup is Test {
    address public admin;
    address public user;
    address public auction;

    AccessControl public accessControl;
    SoulboundERC721Merkle public erc721;
    MockZapRouter public zapRouter;
    CCAToken public ccaToken;
    MockPredicateRegistry public predicateRegistry;
    ValidationHook public validationHook;

    function setUp() public virtual {
        admin = makeAddr("admin");
        vm.deal(admin, 1 ether);
        user = makeAddr("user");
        vm.deal(user, 1 ether);
        auction = makeAddr("auction");

        accessControl = AccessControl(
            address(
                new ERC1967Proxy(
                    address(new AccessControl()), abi.encodeWithSelector(AccessControl.initialize.selector, admin)
                )
            )
        );

        erc721 = SoulboundERC721Merkle(
            address(
                new ERC1967Proxy(
                    address(new SoulboundERC721Merkle()),
                    abi.encodeWithSelector(
                        SoulboundERC721Merkle.initialize.selector, address(accessControl), "Test ERC721", "TEST ERC721"
                    )
                )
            )
        );

        zapRouter = new MockZapRouter();

        ccaToken = CCAToken(
            address(
                new ERC1967Proxy(
                    address(new CCAToken()),
                    abi.encodeWithSelector(
                        CCAToken.initialize.selector, address(accessControl), address(zapRouter), "Test CCA", "TEST CCA"
                    )
                )
            )
        );

        predicateRegistry = new MockPredicateRegistry();

        validationHook = ValidationHook(
            address(
                new ERC1967Proxy(
                    address(new ValidationHook()),
                    abi.encodeWithSelector(
                        ValidationHook.initialize.selector,
                        address(accessControl),
                        address(erc721),
                        block.number + 1000,
                        address(predicateRegistry),
                        "test"
                    )
                )
            )
        );

        vm.startPrank(admin);
        accessControl.grantAccess(erc721.setRoot.selector, address(erc721), admin);
        accessControl.grantAccess(erc721.setBaseURI.selector, address(erc721), admin);
        accessControl.grantAccess(erc721.pause.selector, address(erc721), admin);
        accessControl.grantAccess(erc721.unpause.selector, address(erc721), admin);
        accessControl.grantAccess(erc721.mint.selector, address(erc721), admin);
        accessControl.grantAccess(erc721.ownerMint.selector, address(erc721), admin);
        accessControl.grantAccess(ccaToken.pause.selector, address(ccaToken), admin);
        accessControl.grantAccess(ccaToken.unpause.selector, address(ccaToken), admin);
        accessControl.grantAccess(ccaToken.mint.selector, address(ccaToken), admin);
        accessControl.grantAccess(ccaToken.recoverERC20.selector, address(ccaToken), admin);
        accessControl.grantAccess(ccaToken.setAsset.selector, address(ccaToken), admin);
        accessControl.grantAccess(ccaToken.setWhitelist.selector, address(ccaToken), admin);
        accessControl.grantAccess(validationHook.setAuction.selector, address(validationHook), admin);
        accessControl.grantAccess(validationHook.setToken.selector, address(validationHook), admin);
        accessControl.grantAccess(validationHook.setExpirationBlock.selector, address(validationHook), admin);
        accessControl.grantAccess(validationHook.setRegistry.selector, address(validationHook), admin);
        accessControl.grantAccess(validationHook.setPolicyID.selector, address(validationHook), admin);

        erc721.setRoot(0x008d8adca5d827f5973e6bcc54120a476aa0c76161b0b87e15f66d0e739f8726);
        validationHook.setAuction(auction);
    }
}
