/// What the `styled` field of a transcription request is being asked for.
///
/// One request returns the verbatim transcript and a second version of it side by side, which is
/// what makes a rewrite cost no extra round trip while leaving "what did I actually say"
/// answerable. There are two things worth asking for in that field, and they are not the same
/// job — a rewrite keeps the speaker's language and may reshape the prose; a translation changes
/// the language and may reshape nothing — so the request says which, rather than the call site
/// passing a clause and hoping the sentence around it happens to fit.
///
/// A case rather than two optional parameters, because only one of them may ever be set: two
/// optionals would make "both at once" a state somebody has to remember not to construct.
public enum StyledRequest: Sendable, Equatable {
    /// The transcript rewritten in a style. Carries the clause text from `prompt/style/`.
    case style(clause: String)
    /// The transcript written again in another language, named by the user.
    case translation(language: String)
}
