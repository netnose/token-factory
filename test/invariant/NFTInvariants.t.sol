// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

import {TokenFactory} from "../../src/TokenFactory.sol";
import {FactoryERC721} from "../../src/tokens/FactoryERC721.sol";
import {FactoryERC1155} from "../../src/tokens/FactoryERC1155.sol";

/// @dev Random public mints (paid and free), sale changes, supply cuts and withdrawals on one ERC721 and one ERC1155.
contract NFTHandler is Test {
    uint256 constant BPS = 10_000;
    uint256 constant IDS = 3;

    TokenFactory public factory;
    FactoryERC721 public nft;
    FactoryERC1155 public items;
    address public owner;
    address public platform;
    address[] public buyers;

    uint256 public ghostPaid; // all ETH buyers paid
    uint256 public ghostPlatformExpected; // sum of price * share / BPS over every mint
    uint256 public ghostOwnerWithdrawn;
    uint256 public ghostPlatformWithdrawn;

    constructor(TokenFactory _factory, FactoryERC721 _nft, FactoryERC1155 _items, address _owner, address _platform) {
        factory = _factory;
        nft = _nft;
        items = _items;
        owner = _owner;
        platform = _platform;
        for (uint256 i; i < 3; ++i) {
            address b = makeAddr(string(abi.encodePacked("buyer", vm.toString(i))));
            buyers.push(b);
            vm.deal(b, 1_000_000 ether);
        }
    }

    function buyerCount() external view returns (uint256) {
        return buyers.length;
    }

    function mint721(uint256 buyerSeed, uint256 quantity) public {
        address buyer = buyers[buyerSeed % buyers.length];
        quantity = bound(quantity, 1, 5);
        uint256 cost = nft.price() * quantity;
        vm.prank(buyer);
        try nft.publicMint{value: cost}(quantity) {
            ghostPaid += cost;
            ghostPlatformExpected += cost * nft.protocolShareBps() / BPS;
        } catch {} // sale closed, supply or wallet limit reached
    }

    function mint1155(uint256 buyerSeed, uint256 id, uint256 quantity) public {
        address buyer = buyers[buyerSeed % buyers.length];
        id = id % IDS;
        quantity = bound(quantity, 1, 5);
        (uint256 price,,,) = items.sales(id);
        uint256 cost = price * quantity;
        vm.prank(buyer);
        try items.publicMint{value: cost}(id, quantity) {
            ghostPaid += cost;
            ghostPlatformExpected += cost * items.protocolShareBps() / BPS;
        } catch {}
    }

    function setSale721(uint96 price, uint8 perWallet, bool active) public {
        vm.prank(owner);
        nft.setSale(bound(price, 0, 1 ether), uint64(bound(perWallet, 0, 10)), active);
    }

    function setSale1155(uint256 id, uint96 price, uint8 perWallet, bool active) public {
        vm.prank(owner);
        items.setSale(id % IDS, bound(price, 0, 1 ether), uint64(bound(perWallet, 0, 10)), active);
    }

    function cutSupply721(uint64 newMax) public {
        uint256 minted = nft.totalMinted();
        uint64 current = nft.maxSupply();
        uint256 hi = current == 0 ? minted + 50 : uint256(current) - 1;
        if (hi < minted || hi == 0) return;
        vm.prank(owner);
        nft.setMaxSupply(uint64(bound(newMax, minted == 0 ? 1 : minted, hi)));
    }

    function withdrawOwner721() public {
        uint256 bal = address(nft).balance;
        if (bal == 0) return;
        vm.prank(owner);
        nft.withdraw();
        ghostOwnerWithdrawn += bal;
    }

    function withdrawOwner1155() public {
        uint256 bal = address(items).balance;
        if (bal == 0) return;
        vm.prank(owner);
        items.withdraw();
        ghostOwnerWithdrawn += bal;
    }

    function withdrawPlatform() public {
        uint256 bal = address(factory).balance;
        if (bal == 0) return;
        vm.prank(platform);
        factory.withdraw(payable(makeAddr("vault")));
        ghostPlatformWithdrawn += bal;
    }
}

contract NFTInvariantsTest is Test, ERC721Holder {
    TokenFactory factory;
    FactoryERC721 nft;
    FactoryERC1155 items;
    NFTHandler handler;
    address platform = makeAddr("platform");
    address creator = makeAddr("creator");

    function setUp() public {
        factory = new TokenFactory(new PoolManager(address(this)), platform);
        vm.prank(platform);
        factory.setProtocolShare(1_000);

        vm.startPrank(creator);
        nft = FactoryERC721(
            factory.createERC721(
                TokenFactory.ERC721Params({
                    name: "C",
                    symbol: "C",
                    baseURI: "",
                    contractURI: "",
                    sale: FactoryERC721.SaleConfig({price: 0.01 ether, maxSupply: 200, maxPerWallet: 20, active: true}),
                    royalty: FactoryERC721.RoyaltyConfig(address(0), 0),
                    salt: 0
                })
            )
        );
        items = FactoryERC1155(
            factory.createERC1155(
                TokenFactory.ERC1155Params({
                    name: "I",
                    symbol: "I",
                    uri: "",
                    contractURI: "",
                    royalty: FactoryERC721.RoyaltyConfig(address(0), 0),
                    salt: 0
                })
            )
        );
        for (uint256 id; id < 3; ++id) {
            items.setSale(id, 0.02 ether * (id + 1), 15, true);
            items.setMaxSupply(id, 100);
        }
        vm.stopPrank();

        handler = new NFTHandler(factory, nft, items, creator, platform);
        targetContract(address(handler));
    }

    /// Every wei a buyer paid is either still in a collection, withdrawn by the owner, or the platform's.
    function invariant_ethConservation() public view {
        assertEq(
            handler.ghostPaid(),
            address(nft).balance + address(items).balance + handler.ghostOwnerWithdrawn() + address(factory).balance
                + handler.ghostPlatformWithdrawn()
        );
    }

    /// The platform received exactly its share of every mint, no more, no less.
    function invariant_platformGetsExactShare() public view {
        assertEq(address(factory).balance + handler.ghostPlatformWithdrawn(), handler.ghostPlatformExpected());
    }

    /// Supply caps hold, and minted counts match balances (buyers never transfer in this suite). Per-wallet limits
    /// are enforced per mint against the limit in force at the time; the owner may lower a limit afterwards, so a
    /// global "balance <= current limit" check would not be a valid invariant.
    function invariant_supplyAndBalances() public view {
        uint64 max721 = nft.maxSupply();
        if (max721 != 0) assertLe(nft.totalMinted(), max721, "721 over max supply");
        uint256 sum;
        for (uint256 b; b < handler.buyerCount(); ++b) {
            sum += nft.balanceOf(handler.buyers(b));
        }
        assertEq(sum, nft.totalMinted(), "721 supply != balances");

        for (uint256 id; id < 3; ++id) {
            (, uint64 cap,,) = items.sales(id);
            if (cap != 0) assertLe(items.totalMinted(id), cap, "1155 over max supply");
            uint256 idSum;
            for (uint256 b; b < handler.buyerCount(); ++b) {
                address buyer = handler.buyers(b);
                assertEq(items.balanceOf(buyer, id), items.publicMinted(id, buyer), "1155 balance != minted");
                idSum += items.balanceOf(buyer, id);
            }
            assertEq(idSum, items.totalMinted(id), "1155 supply != balances");
        }
    }
}
