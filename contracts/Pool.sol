// SPDX-FileCopyrightText: 2023 Stake Together Labs <info@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;
import './StakeTogether.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/Ownable.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import { IPool } from './interfaces/IPool.sol';

/// @custom:security-contact security@staketogether.app
contract Pool is Ownable, Pausable, ReentrancyGuard, IMerkleDistributor {
  StakeTogether public stakeTogether;
  Distributor public distribution;

  modifier onlyDistributor() {
    require(msg.sender == address(rewardsContract), 'ONLY_DISTRIBUTOR_CONTRACT');
    _;
  }

  receive() external payable {
    _transferToStakeTogether();
    emit EtherReceived(msg.sender, msg.value);
  }

  fallback() external payable {
    _transferToStakeTogether();
    emit EtherReceived(msg.sender, msg.value);
  }

  function _transferToStakeTogether() private {
    payable(address(stakeTogether)).transfer(address(this).balance);
  }

  constructor(StakeTogether _stakeTogether, Distributor _distributor) payable {
    stakeTogether = StakeTogether(payable(_stakeTogether));
    distribution = Distributor(payable(_distributor));
  }

  /***********************
   ** REWARDS **
   ***********************/

  mapping(uint256 => bytes32) public rewardsMerkleRoots;
  mapping(uint256 => mapping(uint256 => uint256)) private claimedBitMap;

  function addRewardsMerkleRoot(uint256 _epoch, bytes32 merkleRoot) external onlyDistributor {
    require(rewardsMerkleRoots[_epoch] == bytes32(0), 'MERKLE_ALREADY_SET_FOR_EPOCH');
    rewardsMerkleRoots[_epoch] = merkleRoot;
    emit AddRewardsMerkleRoot(_epoch, merkleRoot);
  }

  function removeRewardsMerkleRoot(uint256 _epoch) external onlyOwner {
    require(rewardsMerkleRoots[_epoch] != bytes32(0), 'MERKLE_NOT_SET_FOR_EPOCH');
    rewardsMerkleRoots[_epoch] = bytes32(0);
    emit RemoveRewardsMerkleRoot(_epoch);
  }

  function claimRewards(
    uint256 _epoch,
    uint256 _index,
    address _account,
    uint256 _sharesAmount,
    bytes32[] calldata merkleProof
  ) external nonReentrant whenNotPaused {
    require(rewardsMerkleRoots[epoch] != bytes32(0), 'EPOCH_NOT_FOUND');
    require(_account != address(0), 'INVALID_ADDRESS');
    require(_sharesAmount > 0, 'ZERO_SHARES_AMOUNT');
    if (isClaimed(_epoch, _index)) revert('ALREADY_CLAIMED');

    bytes32 leaf = keccak256(abi.encodePacked(index, _account, _sharesAmount));
    if (!MerkleProof.verify(merkleProof, rewardsMerkleRoots[_epoch], leaf))
      revert('INVALID_MERKLE_PROOF');

    _setRewardsClaimed(_epoch, _index);

    stakeTogether.mintRewards(address(this), _sharesAmount);

    emit ClaimRewards(_epoch, index, _account, _sharesAmount);
  }

  function claimRewardsBatch(
    uint256[] calldata _epochs,
    uint256[] calldata _indices,
    address[] calldata _accounts,
    uint256[] calldata _sharesAmounts,
    bytes32[][] calldata merkleProofs
  ) external nonReentrant {
    uint256 length = _epochs.length;

    require(
      _indices.length == length &&
        _accounts.length == length &&
        _sharesAmounts.length == length &&
        merkleProofs.length == length,
      'INVALID_ARRAYS_LENGTH'
    );

    for (uint256 i = 0; i < length; i++) {
      claimRewards(_epochs[i], _indices[i], _accounts[i], _sharesAmounts[i], merkleProofs[i]);
    }
  }

  function isRewardsClaimed(uint256 _epoch, uint256 _index) public view returns (bool) {
    uint256 claimedWordIndex = _index / 256;
    uint256 claimedBitIndex = _index % 256;
    uint256 claimedWord = claimedBitMap[_epoch][claimedWordIndex];
    uint256 mask = (1 << claimedBitIndex);
    return claimedWord & mask == mask;
  }

  function _setRewardsClaimed(uint256 _epoch, uint256 _index) private {
    uint256 claimedWordIndex = _index / 256;
    uint256 claimedBitIndex = _index % 256;
    claimedBitMap[_epoch][claimedWordIndex] =
      claimedBitMap[_epoch][claimedWordIndex] |
      (1 << claimedBitIndex);
  }
}