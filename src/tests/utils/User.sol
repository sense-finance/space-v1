// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.7.0;
pragma experimental ABIEncoderV2;

// External references
import { IVault, IAsset } from "@balancer-labs/v2-vault/contracts/Vault.sol";
import { IERC20 } from "@balancer-labs/v2-solidity-utils/contracts/openzeppelin/IERC20.sol";

// Internal references
import { ERC20Mintable } from "./Mocks.sol";
import { Space } from "../../Space.sol";

contract User {
    Space space;
    IVault vault;
    ERC20Mintable pt;
    ERC20Mintable target;

    constructor(
        IVault _vault,
        Space _space,
        ERC20Mintable _principal,
        ERC20Mintable _target
    ) public {
        vault = _vault;
        space = _space;
        pt = _principal;
        target = _target;
        pt.approve(address(vault), type(uint256).max);
        target.approve(address(vault), type(uint256).max);
    }

    function join() public {
        join(1e18, 1e18);
    }

    function join(uint256 reqPrincipalIn, uint256 reqTargetIn) public {
        (IERC20[] memory _assets, , ) = vault.getPoolTokens(space.getPoolId());

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(_assets[0]));
        assets[1] = IAsset(address(_assets[1]));

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = type(uint256).max;
        maxAmountsIn[1] = type(uint256).max;

        (uint256 pti, uint256 targeti) = space.getIndices();
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[pti] = reqPrincipalIn;
        amountsIn[targeti] = reqTargetIn;

        vault.joinPool(
            space.getPoolId(),
            address(this),
            address(this),
            IVault.JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(amountsIn),
                fromInternalBalance: false
            })
        );
    }

    function join(uint256 reqPrincipalIn, uint256 reqTargetIn, uint256 minBptOut) public {
        (IERC20[] memory _assets, , ) = vault.getPoolTokens(space.getPoolId());

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(_assets[0]));
        assets[1] = IAsset(address(_assets[1]));

        uint256[] memory maxAmountsIn = new uint256[](2);
        maxAmountsIn[0] = type(uint256).max;
        maxAmountsIn[1] = type(uint256).max;

        (uint256 pti, uint256 targeti) = space.getIndices();
        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[pti] = reqPrincipalIn;
        amountsIn[targeti] = reqTargetIn;

        vault.joinPool(
            space.getPoolId(),
            address(this),
            address(this),
            IVault.JoinPoolRequest({
                assets: assets,
                maxAmountsIn: maxAmountsIn,
                userData: abi.encode(amountsIn, minBptOut),
                fromInternalBalance: false
            })
        );
    }

    function exit(uint256 bptAmountIn) public {
        (IERC20[] memory _assets, , ) = vault.getPoolTokens(space.getPoolId());

        IAsset[] memory assets = new IAsset[](2);
        assets[0] = IAsset(address(_assets[0]));
        assets[1] = IAsset(address(_assets[1]));

        uint256[] memory minAmountsOut = new uint256[](2); // implicit principals

        vault.exitPool(
            space.getPoolId(),
            address(this),
            payable(address(this)),
            IVault.ExitPoolRequest({
                assets: assets,
                minAmountsOut: minAmountsOut,
                userData: abi.encode(bptAmountIn),
                toInternalBalance: false
            })
        );
    }

    function swapIn(bool principalIn) public returns (uint256) {
        return swapIn(principalIn, 1e18);
    }

    function swapIn(bool principalIn, uint256 amountIn) public returns (uint256) {
        return
            vault.swap(
                IVault.SingleSwap({
                    poolId: space.getPoolId(),
                    kind: IVault.SwapKind.GIVEN_IN,
                    assetIn: IAsset(principalIn ? address(pt) : address(target)),
                    assetOut: IAsset(principalIn ? address(target) : address(pt)),
                    amount: amountIn,
                    userData: "0x"
                }),
                IVault.FundManagement({
                    sender: address(this),
                    fromInternalBalance: false,
                    recipient: payable(address(this)),
                    toInternalBalance: false
                }),
                0, // `limit` – no min expectations of return around tokens out testing GIVEN_IN
                type(uint256).max // `deadline` – no deadline
            );
    }

    function swapOut(bool principalIn) public returns (uint256) {
        return swapOut(principalIn, 1e18);
    }

    function swapOut(bool principalIn, uint256 amountOut) public returns (uint256) {
        return
            vault.swap(
                IVault.SingleSwap({
                    poolId: space.getPoolId(),
                    kind: IVault.SwapKind.GIVEN_OUT,
                    assetIn: IAsset(principalIn ? address(pt) : address(target)),
                    assetOut: IAsset(principalIn ? address(target) : address(pt)),
                    amount: amountOut,
                    userData: "0x"
                }),
                IVault.FundManagement({
                    sender: address(this),
                    fromInternalBalance: false,
                    recipient: payable(address(this)),
                    toInternalBalance: false
                }),
                type(uint256).max, // `limit` – no max expectations around tokens out for testing GIVEN_OUT
                type(uint256).max // `deadline` – no deadline
            );
    }
}
