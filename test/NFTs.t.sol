// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

import {TokenFactory} from "../src/TokenFactory.sol";
import {FactoryERC721} from "../src/tokens/FactoryERC721.sol";
import {FactoryERC1155} from "../src/tokens/FactoryERC1155.sol";
import {MintRevenue} from "../src/tokens/MintRevenue.sol";
import {IERC7572} from "../src/interfaces/IERC7572.sol";
import {FactoryFixture} from "./TokenFactory.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

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
                    contractURI: "ipfs://collection.json",
                    sale: FactoryERC721.SaleConfig({price: 0.1 ether, maxSupply: 10, maxPerWallet: 3, active: true}),
                    royalty: FactoryERC721.RoyaltyConfig({receiver: address(0), bps: 500}),
                    salt: bytes32(0)
                })
            )
        );
        items = FactoryERC1155(factory.createERC1155(_erc1155Params(bytes32(0))));
        vm.stopPrank();
    }

    function _erc1155Params(bytes32 salt) internal view returns (TokenFactory.ERC1155Params memory) {
        return TokenFactory.ERC1155Params({
            name: "Items",
            symbol: "ITM",
            uri: "ipfs://items/{id}.json",
            contractURI: "ipfs://items-collection.json",
            royalty: FactoryERC721.RoyaltyConfig({receiver: treasury, bps: 250}),
            salt: salt
        });
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
        // platform share sent to the factory on mint, the rest stays for the owner
        assertEq(address(factory).balance, 0.02 ether);
        assertEq(address(nft).balance, 0.18 ether);
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
        assertEq(address(nft).balance, 0);
        assertEq(address(factory).balance, 0.03 ether);

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
        nft.initialize(
            FactoryERC721.InitParams(
                "x",
                "x",
                "x",
                "x",
                trader,
                0,
                FactoryERC721.SaleConfig(0, 0, 0, false),
                FactoryERC721.RoyaltyConfig(trader, 0)
            )
        );
    }

    function test_protocolShareSnapshotAtCreation() public {
        vm.prank(platform);
        factory.setProtocolShare(0);
        assertEq(nft.protocolShareBps(), PROTOCOL_SHARE);
        vm.prank(creator);
        FactoryERC1155 later = FactoryERC1155(factory.createERC1155(_erc1155Params(bytes32(uint256(1)))));
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
        assertEq(address(factory).balance, 0.105 ether);
        assertEq(address(items).balance, 0.945 ether);
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
        assertEq(address(factory).balance, 0.2 ether);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Per-id URIs
    // ---------------------------------------------------------------------------------------------------------------

    function test_erc1155_tokenURIDefaultsToBase() public {
        assertEq(items.uri(1), "ipfs://items/{id}.json");
        vm.prank(creator);
        items.setTokenURI(1, "ipfs://special/1.json");
        assertEq(items.uri(1), "ipfs://special/1.json");
        assertEq(items.uri(2), "ipfs://items/{id}.json");

        vm.prank(creator);
        items.setURI("ipfs://v2/{id}.json");
        assertEq(items.uri(1), "ipfs://special/1.json");
        assertEq(items.uri(2), "ipfs://v2/{id}.json");

        vm.prank(creator);
        items.setTokenURI(1, ""); // back to the base
        assertEq(items.uri(1), "ipfs://v2/{id}.json");

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        items.setTokenURI(1, "x");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Royalties
    // ---------------------------------------------------------------------------------------------------------------

    function test_royalties_setAtCreation() public view {
        // ERC721: receiver defaulted to the creator
        (address r1, uint256 a1) = nft.royaltyInfo(1, 1 ether);
        assertEq(r1, creator);
        assertEq(a1, 0.05 ether);
        // ERC1155: explicit receiver
        (address r2, uint256 a2) = items.royaltyInfo(7, 1 ether);
        assertEq(r2, treasury);
        assertEq(a2, 0.025 ether);

        assertTrue(nft.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(nft.supportsInterface(type(IERC721).interfaceId));
        assertTrue(items.supportsInterface(type(IERC2981).interfaceId));
        assertTrue(items.supportsInterface(type(IERC1155).interfaceId));
    }

    function test_royalties_ownerManagesAndCapped() public {
        vm.startPrank(creator);
        items.setTokenRoyalty(3, buyer, 1_000);
        (address r, uint256 a) = items.royaltyInfo(3, 1 ether);
        assertEq(r, buyer);
        assertEq(a, 0.1 ether);
        (r, a) = items.royaltyInfo(4, 1 ether);
        assertEq(r, treasury); // other ids keep the default

        items.setTokenRoyalty(3, address(0), 0); // reset to default
        (r,) = items.royaltyInfo(3, 1 ether);
        assertEq(r, treasury);

        vm.expectRevert(MintRevenue.RoyaltyTooHigh.selector);
        nft.setDefaultRoyalty(creator, 1_001);
        nft.setDefaultRoyalty(creator, 0); // remove
        (, a) = nft.royaltyInfo(1, 1 ether);
        assertEq(a, 0);
        vm.stopPrank();

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        nft.setDefaultRoyalty(trader, 100);
    }

    function test_royalties_cappedAtCreation() public {
        TokenFactory.ERC1155Params memory p = _erc1155Params(bytes32(uint256(9)));
        p.royalty.bps = 1_001;
        vm.prank(creator);
        vm.expectRevert(MintRevenue.RoyaltyTooHigh.selector);
        factory.createERC1155(p);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Platform revenue: one withdraw for swap fees + mint revenue
    // ---------------------------------------------------------------------------------------------------------------

    function test_factoryWithdrawCollectsEverything() public {
        // mint revenue
        vm.prank(buyer);
        nft.publicMint{value: 0.3 ether}(3);
        // swap fees
        (, PoolKey memory key) = _launch(500);
        _swap(key, true, -1 ether, 1 ether);

        uint256 expected = 0.03 ether + 0.05 ether * uint256(PROTOCOL_SHARE) / 10_000;
        address payable to = payable(makeAddr("vault"));
        vm.prank(platform);
        assertEq(factory.withdraw(to), expected);
        assertEq(to.balance, expected);
        assertEq(address(factory).balance, 0);
        assertEq(manager.balanceOf(address(factory), 0), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // EIP-4906 (metadata update events) and EIP-7572 (contractURI)
    // ---------------------------------------------------------------------------------------------------------------

    event MetadataUpdate(uint256 _tokenId);
    event BatchMetadataUpdate(uint256 _fromTokenId, uint256 _toTokenId);
    event ContractURIUpdated();

    function test_erc721_eip4906() public {
        assertTrue(nft.supportsInterface(bytes4(0x49064906)), "claims EIP-4906");
        vm.expectEmit(address(nft));
        emit BatchMetadataUpdate(0, type(uint256).max);
        vm.prank(creator);
        nft.setBaseURI("ipfs://v2/");
        vm.prank(creator);
        nft.mint(trader);
        assertEq(nft.tokenURI(1), "ipfs://v2/1");
    }

    function test_erc1155_eip4906Events() public {
        assertFalse(items.supportsInterface(bytes4(0x49064906)), "EIP-4906 id is ERC-721 only");
        vm.expectEmit(address(items));
        emit BatchMetadataUpdate(0, type(uint256).max);
        vm.prank(creator);
        items.setURI("ipfs://v2/{id}.json");

        vm.expectEmit(address(items));
        emit MetadataUpdate(7);
        vm.prank(creator);
        items.setTokenURI(7, "ipfs://special/7.json");
    }

    function test_eip7572_contractURI_nfts() public {
        assertEq(nft.contractURI(), "ipfs://collection.json");
        assertEq(items.contractURI(), "ipfs://items-collection.json");

        vm.expectEmit(address(nft));
        emit ContractURIUpdated();
        vm.prank(creator);
        nft.setContractURI("ipfs://collection-v2.json");
        assertEq(nft.contractURI(), "ipfs://collection-v2.json");

        vm.expectEmit(address(items));
        emit ContractURIUpdated();
        vm.prank(creator);
        items.setContractURI("ipfs://items-v2.json");
        assertEq(items.contractURI(), "ipfs://items-v2.json");

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        nft.setContractURI("x");
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, trader));
        items.setContractURI("x");
    }

    function test_eip7572_emittedAtCreation() public {
        TokenFactory.ERC1155Params memory p = _erc1155Params(bytes32(uint256(42)));
        address predicted = factory.predictAddress(TokenFactory.TokenType.ERC1155, creator, p.salt);
        vm.expectEmit(predicted);
        emit ContractURIUpdated();
        vm.prank(creator);
        factory.createERC1155(p);
    }

    function test_eip7572_contractURI_erc20IsPermanent() public {
        (address token,) = _launch(500);
        assertEq(IERC7572(token).contractURI(), "ipfs://token-meta.json");
        // No owner and no setter: the call below is not part of the token's ABI.
        (bool ok,) = token.call(abi.encodeWithSignature("setContractURI(string)", "x"));
        assertFalse(ok);
        assertEq(IERC7572(token).contractURI(), "ipfs://token-meta.json");
    }

    function test_implementationsCannotBeInitialized() public {
        FactoryERC1155 impl = FactoryERC1155(factory.erc1155Implementation());
        vm.expectRevert();
        impl.initialize(FactoryERC1155.InitParams("x", "x", "x", "x", trader, 0, address(0), 0));
    }
}
