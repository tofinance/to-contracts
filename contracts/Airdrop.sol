// SPDX-FileCopyrightText: 2023 Stake Together Labs <legal@staketogether.app>
// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.18;

import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/security/Pausable.sol';
import '@openzeppelin/contracts/access/AccessControl.sol';
import '@openzeppelin/contracts/security/ReentrancyGuard.sol';
import '@openzeppelin/contracts/utils/cryptography/MerkleProof.sol';
import './Router.sol';
import './StakeTogether.sol';

/// @custom:security-contact security@staketogether.app
contract Airdrop is AccessControl, Pausable, ReentrancyGuard {
  bytes32 public constant ADMIN_ROLE = keccak256('ADMIN_ROLE');
  bytes32 public constant POOL_MANAGER_ROLE = keccak256('POOL_MANAGER_ROLE');

  StakeTogether public stakeTogether;
  Router public distribution;

  event ReceiveEther(address indexed sender, uint amount);
  event FallbackEther(address indexed sender, uint amount);
  event SetStakeTogether(address stakeTogether);
  event SetRouter(address router);
  event AddMerkleRoots(
    uint256 indexed epoch,
    bytes32 poolsRoot,
    bytes32 operatorsRoot,
    bytes32 stakeRoot,
    bytes32 withdrawalsRoot,
    bytes32 rewardsRoot
  );
  event ClaimRewards(uint256 indexed _epoch, address indexed _account, uint256 sharesAmount);
  event ClaimRewardsBatch(address indexed claimer, uint256 numClaims, uint256 totalAmount);
  event SetMaxBatchSize(uint256 maxBatchSize);

  constructor() payable {
    _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    _grantRole(ADMIN_ROLE, msg.sender);
    _grantRole(POOL_MANAGER_ROLE, msg.sender);

    // Todo: initialize stakeTogether and operator as pools fee addresses
  }

  modifier onlyRouter() {
    require(msg.sender == address(distribution), 'ONLY_DISTRIBUTOR_CONTRACT');
    _;
  }

  receive() external payable {
    _transferToStakeTogether();
    emit ReceiveEther(msg.sender, msg.value);
  }

  fallback() external payable {
    _transferToStakeTogether();
    emit FallbackEther(msg.sender, msg.value);
  }

  function setStakeTogether(address _stakeTogether) external onlyRole(ADMIN_ROLE) {
    require(_stakeTogether != address(0), 'STAKE_TOGETHER_ALREADY_SET');
    stakeTogether = StakeTogether(payable(_stakeTogether));
    emit SetStakeTogether(_stakeTogether);
  }

  function setRouter(address _distributor) external onlyRole(ADMIN_ROLE) {
    require(_distributor != address(0), 'DISTRIBUTOR_ALREADY_SET');
    distribution = Router(payable(_distributor));
    emit SetRouter(_distributor);
  }

  function pause() public onlyRole(ADMIN_ROLE) {
    _pause();
  }

  function unpause() public onlyRole(ADMIN_ROLE) {
    _unpause();
  }

  function _transferToStakeTogether() private {
    payable(address(stakeTogether)).transfer(address(this).balance);
  }

  /**************
   ** AIRDROPS **
   **************/

  event AddAirdropMerkleRoot(AirdropType indexed airdropType, uint256 indexed epoch, bytes32 merkleRoot);
  event ClaimAirdrop(
    AirdropType indexed airdropType,
    uint256 indexed epoch,
    address indexed account,
    uint256 sharesAmount
  );
  event ClaimAirdropBatch(
    address indexed claimer,
    AirdropType indexed airdropType,
    uint256 numClaims,
    uint256 totalAmount
  );

  enum AirdropType {
    Pools,
    Operators,
    Stakes,
    Withdrawals,
    Rewards
  }

  mapping(AirdropType => mapping(uint256 => bytes32)) public airdropsMerkleRoots;
  mapping(AirdropType => mapping(uint256 => mapping(uint256 => uint256))) private claimedBitMap;
  uint256 public maxBatchSize = 100;

  function addAirdropMerkleRoot(
    AirdropType _type,
    uint256 _epoch,
    bytes32 merkleRoot
  ) external onlyRouter {
    require(airdropsMerkleRoots[_type][_epoch] == bytes32(0), 'MERKLE_ALREADY_SET_FOR_EPOCH');
    airdropsMerkleRoots[_type][_epoch] = merkleRoot;
    emit AddAirdropMerkleRoot(_type, _epoch, merkleRoot);
  }

  function claimAirdrop(
    AirdropType _type,
    uint256 _epoch,
    address _account,
    uint256 _sharesAmount,
    bytes32[] calldata merkleProof
  ) public nonReentrant whenNotPaused {
    require(airdropsMerkleRoots[_type][_epoch] != bytes32(0), 'EPOCH_NOT_FOUND');
    require(_account != address(0), 'INVALID_ADDRESS');
    require(_sharesAmount > 0, 'ZERO_SHARES_AMOUNT');
    if (isAirdropClaimed(_type, _epoch, _account)) revert('ALREADY_CLAIMED');

    bytes32 leaf = keccak256(abi.encodePacked(_account, _sharesAmount));
    if (!MerkleProof.verify(merkleProof, airdropsMerkleRoots[_type][_epoch], leaf))
      revert('INVALID_MERKLE_PROOF');

    _setAirdropClaimed(_type, _epoch, _account);
    // Todo: implement each type

    stakeTogether.claimRewards(_account, _sharesAmount);
    emit ClaimAirdrop(_type, _epoch, _account, _sharesAmount);
  }

  function claimAirdropBatch(
    AirdropType _type,
    uint256[] calldata _epochs,
    address[] calldata _accounts,
    uint256[] calldata _sharesAmounts,
    bytes32[][] calldata merkleProofs
  ) external nonReentrant whenNotPaused {
    uint256 length = _epochs.length;
    require(length <= maxBatchSize, 'BATCH_SIZE_EXCEEDS_LIMIT');
    require(
      _accounts.length == length && _sharesAmounts.length == length && merkleProofs.length == length,
      'INVALID_ARRAYS_LENGTH'
    );

    uint256 totalAmount = 0;
    for (uint256 i = 0; i < length; i++) {
      claimAirdrop(_type, _epochs[i], _accounts[i], _sharesAmounts[i], merkleProofs[i]);
      totalAmount += _sharesAmounts[i];
    }

    emit ClaimAirdropBatch(msg.sender, _type, length, totalAmount);
  }

  function isAirdropClaimed(
    AirdropType _type,
    uint256 _epoch,
    address _account
  ) public view returns (bool) {
    uint256 index = uint256(keccak256(abi.encodePacked(_type, _epoch, _account)));
    uint256 claimedWordIndex = index / 256;
    uint256 claimedBitIndex = index % 256;
    uint256 claimedWord = claimedBitMap[_type][_epoch][claimedWordIndex];
    uint256 mask = (1 << claimedBitIndex);
    return claimedWord & mask == mask;
  }

  function _setAirdropClaimed(AirdropType _type, uint256 _epoch, address _account) private {
    uint256 index = uint256(keccak256(abi.encodePacked(_type, _epoch, _account)));
    uint256 claimedWordIndex = index / 256;
    uint256 claimedBitIndex = index % 256;
    claimedBitMap[_type][_epoch][claimedWordIndex] =
      claimedBitMap[_type][_epoch][claimedWordIndex] |
      (1 << claimedBitIndex);
  }
}