// SPDX-FileCopyrightText: 2023 Stake Together Labs <legal@staketogether.app>
// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.18;

/// @title Interface for the Airdrop functionality within the Stake Together protocol.
/// @custom:security-contact security@staketogether.app
interface IAirdrop {
  /// @notice Emitted when a new Merkle root is added.
  /// @param epoch The epoch number corresponding to the Merkle root.
  /// @param merkleRoot The Merkle root.
  event AddMerkleRoot(uint256 indexed epoch, bytes32 merkleRoot);

  /// @notice Emitted when a claim is processed.
  /// @param epoch The epoch number related to the claim.
  /// @param index The index of the claim within the Merkle tree.
  /// @param account The address of the account making the claim.
  /// @param sharesAmount The amount of shares claimed.
  /// @param merkleProof The Merkle proof corresponding to the claim.
  event Claim(
    uint256 indexed epoch,
    uint256 index,
    address indexed account,
    uint256 sharesAmount,
    bytes32[] merkleProof
  );

  /// @notice Emitted when a batch of claims is processed.
  /// @param claimer The address making the batch claims.
  /// @param numClaims The number of claims in the batch.
  /// @param totalAmount The total amount of the claims in the batch.
  event ClaimBatch(address indexed claimer, uint256 numClaims, uint256 totalAmount);

  /// @notice Emitted when ETH is received by the contract.
  /// @param amount The amount of ETH received.
  event ReceiveEther(uint256 amount);

  /// @notice Emitted when the router address is set.
  /// @param router The address of the router.
  event SetRouter(address router);

  /// @notice Emitted when the StakeTogether contract address is set.
  /// @param stakeTogether The address of the StakeTogether contract.
  event SetStakeTogether(address stakeTogether);

  /// @notice Initializes the contract with initial settings.
  function initialize() external;

  /// @notice Pauses all contract functionalities.
  /// @dev Only callable by the admin role.
  function pause() external;

  /// @notice Unpauses all contract functionalities.
  /// @dev Only callable by the admin role.
  function unpause() external;

  /// @notice Receives Ether and emits an event logging the sender and amount.
  receive() external payable;

  /// @notice Transfers any extra amount of ETH in the contract to the StakeTogether fee address.
  /// @dev Only callable by the admin role.
  function transferExtraAmount() external;

  /// @notice Sets the StakeTogether contract address.
  /// @param _stakeTogether The address of the StakeTogether contract.
  /// @dev Only callable by the admin role.
  function setStakeTogether(address _stakeTogether) external;

  /// @notice Sets the Router contract address.
  /// @param _router The address of the router.
  /// @dev Only callable by the admin role.
  function setRouter(address _router) external;

  /// @notice Adds a new Merkle root for a given epoch.
  /// @param _epoch The epoch number.
  /// @param merkleRoot The Merkle root.
  /// @dev Only callable by the router.
  function addMerkleRoot(uint256 _epoch, bytes32 merkleRoot) external;

  /// @notice Claims a reward for a specific epoch.
  /// @param _epoch The epoch number.
  /// @param _index The index in the Merkle tree.
  /// @param _account The address claiming the reward.
  /// @param _sharesAmount The amount of shares to claim.
  /// @param merkleProof The Merkle proof required to claim the reward.
  /// @dev Verifies the Merkle proof and transfers the reward shares.
  function claim(
    uint256 _epoch,
    uint256 _index,
    address _account,
    uint256 _sharesAmount,
    bytes32[] calldata merkleProof
  ) external;

  /// @notice Checks if a reward has been claimed for a specific index and epoch.
  /// @param _epoch The epoch number.
  /// @param _index The index in the Merkle tree.
  /// @return Returns true if the reward has been claimed, false otherwise.
  function isClaimed(uint256 _epoch, uint256 _index) external view returns (bool);
}
