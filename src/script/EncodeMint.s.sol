
 // SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {Message, INativeBridge} from "../interfaces/IHarborBridge.sol";

contract EncodeMint is Script {
    function run() external {
        Message memory message = Message({
            srcChainId: 1002,
            dstChainId: 8453200012,
            nonce: 1,
            sender: 0x70997970C51812dc3A010C7d01b50e0d17dc79C8,
            recipient: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266,
            amount: 99700000000000000000,
            hookGasLimit: 0,
            hookData: ""
        });

        bytes[] memory signatures = new bytes[](2);

        // Validator 2 first, then Validator 1 (ascending address order).
        signatures[0] = hex"2c09e44c1c8cb89142ffa418448d83f04075b3380d1714b4f6bd6c1ff66b3a9a0f7eba80ed6002df55334dab3f0852e9d7c72491af3c26e0c6975f326dd1a0121b";
        signatures[1] = hex"d50211f8541a0d135003c7d420297c0f33baf26a3c9b20c918807179fb53c825067c2599e8edc146f1d67816838622b20f2c227037a31d27b4a4b563389338f01c";

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        INativeBridge(0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512)
            .unlock(message, signatures);

        vm.stopBroadcast();
    }
}
