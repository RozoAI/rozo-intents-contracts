// SPDX-License-Identifier: BSD-2-Clause
pragma solidity 0.8.20;

import { Script, console2 } from "forge-std/Script.sol";
import { VmSafe } from "forge-std/Vm.sol";
import { DeployV2 } from "./DeployV2.s.sol";
import { MPForwarderFactoryV2 } from "../src/MPForwarderFactoryV2.sol";
import { MPForwarderV2 } from "../src/MPForwarderV2.sol";
import { IERC20Minimal } from "../src/interface/IERC20Minimal.sol";

/**
 * @title FlushDrill
 * @notice Small-amount end-to-end drill: pay a clone address, then `cloneForwarderAndFlush` it so the
 *         funds land on the production hub (P2.destination()). Testnets always; a mainnet only when
 *         MAINNET_CHAIN_ID equals the RPC chain id (same rule as DeployV2).
 *         Two independent legs, each gated by its env var:
 *           DRILL_NATIVE_WEI   native amount (wei) paid to the "native" clone, flushed with token = 0x0
 *           DRILL_TOKEN        ERC-20 address paid to the "erc20" clone (0x0 = skip)
 *           DRILL_TOKEN_UNITS  ERC-20 amount in token units
 *           DRILL_LABEL        salt label, default "test:20261025" (salts = keccak256(label ‖ ":native" / ":erc20"))
 *         Same safety rails as DeployV2: RPC chain id check, testnet-only broadcast allowlist, Arc fee floor,
 *         key only from DEPLOYER_PRIVATE_KEY. Evidence is what eth_getBalance / Transfer logs show after
 *         the broadcast, not this script's simulation output.
 */
contract FlushDrill is Script {
    struct Cfg {
        uint256 chainId;
        address f2;
        address p2;
        address hub;
        uint256 saltNative;
        uint256 saltErc20;
        uint256 nativeWei;
        address token;
        uint256 tokenUnits;
        bool pay;
        bool isUSDT;
    }

    function _load() internal returns (Cfg memory c, DeployV2 d) {
        d = new DeployV2();
        c.chainId = d.rpcChainId();
        c.f2 = d.predictFactory();
        c.p2 = d.predictParent(c.f2);
        require(c.f2.code.length != 0 && c.p2.code.length != 0, "F2/P2 not deployed on this chain");
        c.hub = MPForwarderV2(payable(c.p2)).destination();
        require(c.hub == d.HUB(), "P2 destination is not the production hub");
        string memory label = vm.envOr("DRILL_LABEL", string("test:20261025"));
        c.saltNative = uint256(keccak256(abi.encodePacked(label, ":native")));
        c.saltErc20 = uint256(keccak256(abi.encodePacked(label, ":erc20")));
        c.nativeWei = vm.envOr("DRILL_NATIVE_WEI", uint256(0));
        c.token = vm.envOr("DRILL_TOKEN", address(0));
        c.tokenUnits = vm.envOr("DRILL_TOKEN_UNITS", uint256(0));
        c.pay = vm.envOr("DRILL_PAY", true);
        c.isUSDT = vm.envOr("DRILL_IS_USDT", false);
    }

    function _report(Cfg memory c, string memory when) internal view {
        MPForwarderFactoryV2 factory = MPForwarderFactoryV2(c.f2);
        console2.log(when);
        console2.log("  hub native       ", c.hub.balance);
        if (c.token != address(0)) console2.log("  hub token        ", IERC20Minimal(c.token).balanceOf(c.hub));
        console2.log("  clone (native)   ", factory.getCloneAddress(c.p2, c.saltNative));
        console2.log("  clone (erc20)    ", factory.getCloneAddress(c.p2, c.saltErc20));
        console2.log("  clone native left", factory.getCloneAddress(c.p2, c.saltNative).balance);
        if (c.token != address(0)) {
            console2.log("  clone token left ", IERC20Minimal(c.token).balanceOf(factory.getCloneAddress(c.p2, c.saltErc20)));
        }
    }

    function run() external {
        (Cfg memory c, DeployV2 d) = _load();
        bool broadcasting = vm.isContext(VmSafe.ForgeContext.ScriptBroadcast);
        uint256 mainnetChainId = vm.envOr("MAINNET_CHAIN_ID", uint256(0));
        if (broadcasting && !d.isBroadcastAllowed(c.chainId, mainnetChainId)) revert DeployV2.BroadcastNotAllowed(c.chainId);
        console2.log("chainId / F2 / P2 / hub", c.chainId);
        console2.log(c.f2, c.p2, c.hub);
        _report(c, "before");

        uint256 pk = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        if (broadcasting) {
            if (pk == 0) revert DeployV2.MissingDeployerKey();
            d.requireArcFee(c.chainId);
        }
        if (pk != 0) vm.startBroadcast(pk);
        _legs(c);
        if (pk != 0) vm.stopBroadcast();

        _report(c, "after");
    }

    function _legs(Cfg memory c) internal {
        MPForwarderFactoryV2 factory = MPForwarderFactoryV2(c.f2);
        if (c.nativeWei > 0 || (!c.pay && c.token == address(0))) {
            address clone = factory.getCloneAddress(c.p2, c.saltNative);
            if (c.pay) {
                (bool ok,) = clone.call{ value: c.nativeWei }("");
                require(ok, "native pay failed");
            }
            require(clone.balance > 0, "native clone has nothing to flush");
            factory.cloneForwarderAndFlush(c.p2, c.saltNative, address(0), false);
        }
        if (c.token != address(0)) {
            address clone = factory.getCloneAddress(c.p2, c.saltErc20);
            if (c.pay && c.tokenUnits > 0) {
                if (c.isUSDT) {
                    (bool ok,) = c.token.call(abi.encodeWithSelector(IERC20Minimal.transfer.selector, clone, c.tokenUnits));
                    require(ok, "token pay failed");
                } else {
                    require(IERC20Minimal(c.token).transfer(clone, c.tokenUnits), "token pay failed");
                }
            }
            require(IERC20Minimal(c.token).balanceOf(clone) > 0, "erc20 clone has nothing to flush");
            factory.cloneForwarderAndFlush(c.p2, c.saltErc20, c.token, c.isUSDT);
        }
    }
}
