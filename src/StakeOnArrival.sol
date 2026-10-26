    // SPDX-License-Identifier: MIT
    pragma solidity ^0.8.28;

    import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
    import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
    import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

    import {IBridgeHookReceiver} from "./interfaces/IHarborBridge.sol";
    import {IHarborStaking} from "./interfaces/IHarborStaking.sol";

    contract StakeOnArrival is IBridgeHookReceiver, ReentrancyGuard {
        using SafeERC20 for IERC20;

        address public immutable bridge;
        IERC20 public immutable wrappedToken;
        IHarborStaking public immutable staking;
        uint256 public immutable pid;

        event StakeAttempted(
            address indexed beneficiary,
            uint256 amount,
            bool success
        );

        modifier onlyBridge() {
            require(
                msg.sender == bridge,
                "StakeOnArrival: caller is not bridge"
            );
            _;
        }

        constructor(
            address bridgeAddress,
            address wrappedTokenAddress,
            address stakingAddress,
            uint256 pid_
        ) {
            require(bridgeAddress != address(0), "StakeOnArrival: zero bridge");
            require(
                wrappedTokenAddress != address(0),
                "StakeOnArrival: zero wrapped token"
            );
            require(
                stakingAddress != address(0),
                "StakeOnArrival: zero staking"
            );

            bridge = bridgeAddress;
            wrappedToken = IERC20(wrappedTokenAddress);
            staking = IHarborStaking(stakingAddress);
            pid = pid_;
        }

        function onBridgeReceived(
            uint256 srcChainId,
            address sender,
            uint256 amount,
            bytes calldata hookData
        ) external override onlyBridge nonReentrant {
            // These values are provided by the bridge. The source chain and sender
            // are not used to determine the staking beneficiary.
            srcChainId;
            sender;

            if (hookData.length != 32 || amount == 0) {
                emit StakeAttempted(address(0), amount, false);
                return;
            }

            address beneficiary = abi.decode(hookData, (address));

            if (beneficiary == address(0)) {
                emit StakeAttempted(beneficiary, amount, false);
                return;
            }

            // Tokens have already been minted to this hook by the bridge.
            // If staking fails, catch the failure and return the tokens to the
            // beneficiary instead of reverting the bridge transaction.
            try this.stakeFor(beneficiary, amount) {
                emit StakeAttempted(beneficiary, amount, true);
            } catch {
                wrappedToken.safeTransfer(beneficiary, amount);
                emit StakeAttempted(beneficiary, amount, false);
            }
        }

        function stakeFor(address beneficiary, uint256 amount) external {
            require(
                msg.sender == address(this),
                "StakeOnArrival: internal call only"
            );

            wrappedToken.safeIncreaseAllowance(address(staking), amount);
            staking.deposit(pid, amount, beneficiary);

            // Clear any unused allowance after a successful deposit.
            wrappedToken.forceApprove(address(staking), 0);
        }
    }
