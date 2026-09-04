using Xunit;

// The log router is process-global: installing a MemoryLogSink captures every entry the whole
// process emits, not only the ones the installing test provoked. xUnit runs test classes in
// parallel by default, so a class asserting on what it logged can read an entry produced by a
// class running beside it.
//
// That is not hypothetical. FallbackTranscriberTests picked up the handover line from
// DictationJourneyTests, which hedges with the same 20 ms delay and names its second backend
// "fallback", and failed on roughly one full run in five while passing every time its own class
// was run alone. A test that only fails in company is worse than one that always fails, because
// the usual response is to run it again.
//
// Serialising the assembly costs about two seconds — 631 tests go from ~1 s to ~3 s — and buys
// determinism outright: eight consecutive full runs green, against one failure in five before.
// The alternative is remembering forever which classes may log while another class is watching.
[assembly: CollectionBehavior(DisableTestParallelization = true)]
