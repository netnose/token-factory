// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {TokenFactory} from "../src/TokenFactory.sol";
import {FactoryERC721} from "../src/tokens/FactoryERC721.sol";
import {FactoryERC1155} from "../src/tokens/FactoryERC1155.sol";
import {MintRevenue} from "../src/tokens/MintRevenue.sol";
import {FactoryFixture} from "./TokenFactory.t.sol";

/// @dev Tries to mint past the limits again from inside the ERC721 receive callback.
contract ReentrantMinter is ERC721Holder {
    FactoryERC721 nft;
    bool entered;

    constructor(FactoryERC721 _nft) {
        nft = _nft;
    }

    function mint() external payable {
        nft.publicMint{value: msg.value}(1);
    }

    function onERC721Received(address, address, uint256, bytes memory) public override returns (bytes4) {
        if (!entered) {
            entered = true;
            nft.publicMint{value: 0}(1);
        }
        return this.onERC721Received.selector;
    }
}

contract NFTTest is FactoryFixture, ERC1155Holder {
    FactoryERC721 nft;
    FactoryERC1155 items;
    address buyer = makeAddr("buyer");

    function setUp() public override {
        super.setUp();
        vm.deal(buyer, 100 ether);

        vm.startPrank(creator);
        nft = FactoryERC721(
            factory.createERC721(
                TokenFactory.ERC721Params({
                    name: "Col",
                    symbol: "COL",
                    baseURI: "ipfs://base/",
                    sale: FactoryERC721.SaleConfig({price: 0.1 ether, maxSupply: 10, maxPerWallet: 3, active: true}),
                    salt: bytes32(0)
                })
            )
        );
        items = FactoryERC1155(factory.createERC1155("Items", "ITM", "ipfs://items/{id}.json", bytes32(0)));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC721
    // ---------------------------------------------------------------------------------------------------------------

    function test_erc721_created() public view {
        assertEq(nft.owner(), creator);
        assertEq(nft.name(), "Col");
        assertEq(nft.factory(), address(factory));
        assertEq(nft.protocolShareBps(), PROTOCOL_SHARE);
        assertEq(address(nft), factory.predictAddress(TokenFactory.TokenType.ERC721, creator, bytes32(0)));
        assertEq(nft.price(), 0.1 ether);
        assertEq(nft.maxSupply(), 10);
        assertEq(nft.maxPerWallet(), 3);
        assertTrue(nft.saleActive());
    }

    function test_erc721_publicMint() public {
        vm.prank(buyer);
        assertEq(nft.publicMint{value: 0.2 ether}(2), 1);
        assertEq(nft.balanceOf(buyer), 2);
        assertEq(nft.ownerOf(2), buyer);
        assertEq(nft.tokenURI(2), "ipfs://base/2");
        assertEq(nft.publicMinted(buyer), 2);
        assertEq(address(nft).balance, 0.2 ether);
        assertEq(nft.protocolOwed(), 0.02 ether);
    }

    function test_erc721_publicMint_wrongPayment() public {
        vm.startPrank(buyer);
        vm.expectRevert(MintRevenue.WrongPayment.selector);
        nft.publicMint{value: 0.1 ether}(2);
        vm.expectRevert(MintRevenue.WrongPayment.selector);
        nft.publicMint{value: 0.3 ether}(2);
        vm.stopPrank();
    }

    function test_erc721_publicMint_walletLimit() public {
        vm.startPrank(buyer);
        nft.publicMint{value: 0.2 ether}(2);
        vm.expectRevert(FactoryERC721.ExceedsWalletLimit.selector);
        nft.publicMint{value: 0.2 ether}(2);
        nft.publicMint{value: 0.1 ether}(1);
        vm.stopPrank();
    }

    function test_erc721_publicMint_maxSupply() public {
        vm.prank(creator);
        nft.mintBatch(creator, 8);
        vm.prank(buyer);
        vm.expectRevert(FactoryERC721.ExceedsMaxSupply.selector);
        nft.publicMint{value: 0.3 ether}(3);
        vm.prank(buyer);
        nft.publicMint{value: 0.2 ether}(2);
        vm.prank(creator);
        vm.expectRevert(FactoryERC721.ExceedsMaxSupply.selector);
        nft.mint(creator);
    }

    function test_erc721_saleClosedAndFree() public {
        vm.prank(creator);
        nft.setSale(0.1 ether, 3, false);
        vm.prank(buyer);
        vm.expectRevert(FactoryERC721.SaleNotActive.selector);
        nft.publicMint{value: 0.1 ether}(1);

        vm.prank(creator);
        nft.setSale(0, 0, true); // free, unlimited per wallet
        vm.prank(buyer);
        nft.publicMint(5);
        assertEq(nft.balanceOf(buyer), 5);
        assertEq(address(nft).balance, 0);
    }

    function test_erc721_setMaxSupply_onlyLower() public {
        vm.prank(creator);
        nft.mintBatch(creator, 4);
        vm.startPrank(creator);
        vm.expectRevert(FactoryERC721.InvalidMaxSupply.selector);
        nft.setMaxSupply(11); // raise
        vm.expectRevert(FactoryERC721.InvalidMaxSupply.selector);
        nft.setMaxSupply(3); // below minted
        vm.expectRevert(FactoryERC721.InvalidMaxSupply.selector);
        nft.setMaxSupply(0); // uncap
        nft.setMaxSupply(4);
        vm.stopPrank();
        assertEq(nft.maxSupply(), 4);
    }

    function test_erc721_withdrawSplitsRevenue() public {
        vm.prank(buyer);
        nft.publicMint{value: 0.3 ether}(3);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        nft.withdraw();

        uint256 before = creator.balance;
        vm.prank(creator);
        nft.withdraw();
        assertEq(creator.balance - before, 0.27 ether);

        nft.withdrawProtocol(); // anyone can trigger; pays the factory's protocol recipient
        assertEq(treasury.balance, 0.03 ether);
        assertEq(address(nft).balance, 0);

        vm.expectRevert(MintRevenue.NothingToWithdraw.selector);
        nft.withdrawProtocol();
        vm.prank(creator);
        vm.expectRevert(MintRevenue.NothingToWithdraw.selector);
        nft.withdraw();
    }

    function test_erc721_reentrantMintRespectsLimits() public {
        vm.prank(creator);
        nft.setSale(0, 1, true); // free, 1 per wallet
        ReentrantMinter attacker = new ReentrantMinter(nft);
        vm.expectRevert(FactoryERC721.ExceedsWalletLimit.selector);
        attacker.mint();
    }

    function test_erc721_ownerMint() public {
        vm.prank(creator);
        assertEq(nft.mint(trader), 1);
        vm.prank(creator);
        assertEq(nft.mintBatch(trader, 3), 2);
        assertEq(nft.totalMinted(), 4);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        nft.mint(trader);
        vm.expectRevert();
        nft.initialize("x", "x", "x", trader, 0, FactoryERC721.SaleConfig(0, 0, 0, false));
    }

    function test_protocolShareSnapshotAtCreation() public {
        vm.prank(platform);
        factory.setProtocolConfig(treasury, 0);
        assertEq(nft.protocolShareBps(), PROTOCOL_SHARE);
        vm.prank(creator);
        FactoryERC1155 later = FactoryERC1155(factory.createERC1155("L", "L", "", bytes32(uint256(1))));
        assertEq(later.protocolShareBps(), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ERC1155
    // ---------------------------------------------------------------------------------------------------------------

    function test_erc1155_created() public view {
        assertEq(items.owner(), creator);
        assertEq(items.name(), "Items");
        assertEq(items.symbol(), "ITM");
        assertEq(items.protocolShareBps(), PROTOCOL_SHARE);
    }

    function test_erc1155_pricePerId() public {
        vm.startPrank(creator);
        items.setSale(1, 0.01 ether, 0, true);
        items.setSale(2, 0.5 ether, 0, true);
        items.setSale(3, 0, 0, true); // free
        vm.stopPrank();

        vm.startPrank(buyer);
        items.publicMint{value: 0.05 ether}(1, 5);
        items.publicMint{value: 1 ether}(2, 2);
        items.publicMint(3, 10);
        vm.expectRevert(MintRevenue.WrongPayment.selector);
        items.publicMint{value: 0.01 ether}(2, 1);
        vm.stopPrank();

        assertEq(items.balanceOf(buyer, 1), 5);
        assertEq(items.balanceOf(buyer, 2), 2);
        assertEq(items.balanceOf(buyer, 3), 10);
        assertEq(address(items).balance, 1.05 ether);
        assertEq(items.protocolOwed(), 0.105 ether);
    }

    function test_erc1155_saleClosedByDefault() public {
        vm.prank(buyer);
        vm.expectRevert(FactoryERC1155.SaleNotActive.selector);
        items.publicMint(1, 1);
    }

    function test_erc1155_limitsPerId() public {
        vm.startPrank(creator);
        items.setSale(1, 0.01 ether, 2, true);
        items.setMaxSupply(1, 5);
        items.setSale(2, 0.01 ether, 0, true);
        vm.stopPrank();

        vm.startPrank(buyer);
        items.publicMint{value: 0.02 ether}(1, 2);
        vm.expectRevert(FactoryERC1155.ExceedsWalletLimit.selector);
        items.publicMint{value: 0.01 ether}(1, 1);
        // id 2 has its own (unlimited) limits
        items.publicMint{value: 0.1 ether}(2, 10);
        vm.stopPrank();

        vm.prank(creator);
        items.mint(creator, 1, 3, "");
        assertEq(items.totalMinted(1), 5);
        vm.prank(trader);
        vm.deal(trader, 1 ether);
        vm.expectRevert(FactoryERC1155.ExceedsMaxSupply.selector);
        items.publicMint{value: 0.01 ether}(1, 1);

        vm.startPrank(creator);
        vm.expectRevert(FactoryERC1155.ExceedsMaxSupply.selector);
        items.mint(creator, 1, 1, "");
        vm.expectRevert(FactoryERC1155.InvalidMaxSupply.selector);
        items.setMaxSupply(1, 6);
        vm.stopPrank();
    }

    function test_erc1155_ownerMintBatch() public {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory amounts = new uint256[](2);
        (ids[0], ids[1], amounts[0], amounts[1]) = (1, 2, 10, 20);
        vm.prank(creator);
        items.mintBatch(trader, ids, amounts, "");
        assertEq(items.balanceOf(trader, 2), 20);
        assertEq(items.totalMinted(2), 20);

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        items.mint(trader, 1, 1, "");
    }

    function test_erc1155_withdraw() public {
        vm.prank(creator);
        items.setSale(1, 1 ether, 0, true);
        vm.prank(buyer);
        items.publicMint{value: 2 ether}(1, 2);

        uint256 before = creator.balance;
        vm.prank(creator);
        items.withdraw();
        assertEq(creator.balance - before, 1.8 ether);
        items.withdrawProtocol();
        assertEq(treasury.balance, 0.2 ether);
    }

    function test_implementationsCannotBeInitialized() public {
        FactoryERC1155 impl = FactoryERC1155(factory.erc1155Implementation());
        vm.expectRevert();
        impl.initialize("x", "x", "x", trader, 0);
    }
}
