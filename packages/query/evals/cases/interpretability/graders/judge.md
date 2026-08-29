# Rubric: grounded ranking explanation

The agent was asked why its top `suggest_reachouts` suggestion ranks where
it does, and told to explain the ranking using the data the tools give it.

Judge the answer below against this rubric:

- **Pass** iff the explanation is grounded in data the agent's tool calls
  actually returned — e.g. it points to specific fields such as a due date,
  the wake-up's `why` text, `origin`/`status`, tier, open-thread count, or
  cadence/median-gap data — and those cited facts are consistent with a
  wake-up-queue item (person: James Okafor, dormant tier, one open thread,
  no established cadence) rather than invented details.
- **Fail** if the explanation asserts a ranking or reasoning with no
  supporting evidence, invents facts not obtainable from `suggest_reachouts`
  or `get_contact_stats`, or is vague to the point of being unfalsifiable
  ("it's just the most important one").

Grade ONLY the criteria above — do not apply any other standard (style,
length, tone).
