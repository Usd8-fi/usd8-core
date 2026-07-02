// SPDX-License-Identifier: BUSL-1.1
//  __  __   ______   ______   ______
// /_/\/_/\ /_____/\ /_____/\ /_____/\
// \:\ \:\ \\::::_\/_\:::_ \ \\:::_:\ \
//  \:\ \:\ \\:\/___/\\:\ \ \ \\:\_\:\ \
//   \:\ \:\ \\_::._\:\\:\ \ \ \\::__:\ \
//    \:\_\:\ \ /____\:\\:\/.:| |\:\_\:\ \
//     \_____\/ \_____\/ \____/_/ \_____\/

pragma solidity 0.8.28;

/// @title  IInsuredTokenAdapter
/// @notice Per-insured-token rate adapter for {DefiInsurance}. One immutable,
///         ownerless instance per listed token; the adapter CLASS encodes how
///         that token kind is measured — the core contract stays generic.
///
///         Two metrics, deliberately separate because they can differ per
///         token kind (a 4626 vault uses the same rate for both; an AMM LP
///         token needs mark-to-market for valuation but an IL-immune
///         invariant metric for the trigger):
///         - {valuationRate}: what one token is WORTH in underlying. Read by
///           the off-chain settler at historical blocks to value losses.
///         - {triggerState}: a loss-only-decreasing metric vs its reference
///           (typically a high-water mark held by the adapter). Read by
///           {DefiInsurance.openTriggeredIncident} for the permissionless
///           depeg trigger. MUST NOT be derivable-downward by market moves,
///           IL, or donations — only by genuine loss of backing; a class that
///           cannot provide such a metric returns reference == 0 (no
///           auto-trigger; admin opens only).
interface IInsuredTokenAdapter {
    /// @notice WAD-scaled underlying per 1e18 units of the insured token.
    ///         Pure view of current chain state so the settler can read it at
    ///         any historical block via an archive node.
    function valuationRate() external view returns (uint256);

    /// @notice The trigger metric and its reference.
    /// @return current         The metric now (WAD).
    /// @return referenceRate   The no-loss reference (e.g. high-water mark);
    ///                         0 = this adapter provides no auto-trigger.
    /// @return referenceBlock  Block the reference was observed at — becomes
    ///                         {DefiInsurance-Incident.referenceBlock} (the
    ///                         pre-incident valuation point) on triggered opens.
    function triggerState() external view returns (uint256 current, uint256 referenceRate, uint64 referenceBlock);

    /// @notice Checkpoint the reference (ratchet a high-water mark, record an
    ///         observation, …). Permissionless and safety-optional: a stale
    ///         reference only makes the trigger need a deeper real drop, never
    ///         fires it falsely. No-op for stateless adapters.
    function poke() external;
}
