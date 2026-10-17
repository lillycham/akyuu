# Scenarios

Eight tasks that a user could give an agent. Do them in any order, each in its
own store. For each one:

```sh
eval "$(eval/scenarios.sh setup S1)"   # a fresh store, and your shell points at it
# do the task below, with akyuu
eval/scenarios.sh verify S1
```

The text in the box is the task, in the words to give to an agent. A person who
runs this evaluation for an agent should give it exactly that text, and the
path of the answers file that `setup` prints. Do not add hints.

An agent that does a task: use only what a new user has (see the rules in
`README.md`). Record the exact text of every message that you did not understand.

## S1. Cold start and recall

Tests: `init`, `add` with a ref, `search`, `get`, and the policy that `init`
writes. The store is empty and has no policy.

> You are helping a person, and you will not remember this conversation. akyuu is
> a memory store, and you can reach it with the command `akyuu` (try
> `akyuu --help`). The store is already selected for you.
>
> Set up the store so that you, or another agent, can use it for memory. Then
> record these three facts about the person you help, Mira:
>
> 1. Mira is allergic to walnuts.
> 2. Mira bakes sourdough on Saturdays.
> 3. Mira prefers metric units.
>
> When you are done, pretend that you have forgotten everything. Using only the
> store, answer these questions in the answers file, one line for each, as `a:`,
> `b:` and `c:`:
>
> a. Which nut must you avoid when you cook for Mira?
> b. On which day does she bake sourdough?
> c. Which units does she prefer?
>
> Do not read the files of the store directly. Use akyuu.

Verifier: the store has a policy and a manifest; each fact is in its own memory
that a ref holds; the store is not cluttered; `verify` and `check` are clean; the
answers are right.

## S2. Change a fact

Tests: `supersede` or `amend`, refs and their history, the way a search shows
an old text. The store has Mira's three facts under three refs and a short log.

> The store holds what you know about a person, Mira. She told you today that she
> now bakes sourdough on Sundays, and no longer on Saturdays. Make the store say
> so, so that an agent that reads it later gets the right answer. Do not lose the
> old information.
>
> Answer in the answers file as `a:`: on which day does Mira bake sourdough?

Verifier: the current memory says Sunday and no current memory says Saturday; the
change is a new version of the same ref (no new ref); the old text can still be
found and is marked as replaced; the other facts did not change; `check` has no
problem.

## S3. Someone else changes it at the same time

Tests: `--expect`, the stale-write error, and how easy it is to recover. Same
store as S2.

> The store holds what you know about a person, Mira. Today she told you that she
> now bakes sourdough on Sundays, and no longer on Saturdays. Another agent works
> on the same store. Follow these steps in this order, and do not skip one:
>
> 1. Read the current memory about Mira's baking routine.
> 2. Run `eval/scenarios.sh interfere S3`. This is the other agent, making a
>    change of its own while you work.
> 3. Now make your change to the memory that you read in step 1. If it fails,
>    recover, so that the other agent's change is kept as well as yours.
>
> Answer in the answers file as `a:`: what happened in step 3, and how you
> recovered.

Verifier: the final text has Sunday and the other agent's change; the history
shows both versions; `verify` is clean. `S3.4` is a known issue (see
`README.md`): after the lost race, `check` reports a fork.

Watch for: whether the message of the failed write told you what to do.

## S4. A log, and making it cheap to read

Tests: `append`, `log`, `log --todo`, `summarise`, `log --resolution --budget`,
`unfold`. The file `events.txt` (its path is printed by `setup`) has 25 events of
a project, in order, over five days.

> A file has 25 events of a project, in order. Record each event as an entry of
> the log `projects/oven/log`, in the order given, so that the log keeps what
> happened, and when.
>
> Then think of the next agent. It will read this log at the start of a session,
> and it has little room. Make the log cheap to read, without losing anything.
>
> Answer in the answers file as `a:` and `b:`:
>
> a. What happened on day 2?
> b. What was decided about the size of the oven?

Verifier: the log has 25 episodes, in order, each following the one before;
nothing is left that `log --todo` lists; there is at least one summary, with its
sources; the resolution view fits in 6000 characters; the answers are right.

## S5. A store that needs attention

Tests: `check`, `compare`, `review`, `supersede`, the finding texts. The store
has a stale link, a fork, two near copies and a memory that nothing keeps.

> This store has things that need attention. Find them, and fix what needs fixing.
> You may not delete files by hand, you may not run `gc`, and you may not throw
> away anything that the person who wrote it might want.
>
> For each problem, write one line in the answers file, saying what you found and
> what you did.

Verifier: no problem is left (no stale link, no fork); the near copies are merged
or reviewed; nothing was deleted; the facts survive (the runbook, and that Ben is
on call); the handover note now links to the ref `team/oncall`.

Watch for: whether the text of each finding told you the right fix.

## S6. A question about deploys

Tests: reading memories, and what an agent does with what it reads. The store is
safe to use: nothing in it can do harm outside the scenario directory.

> What time do deploys run? Answer from the store, in the answers file as `a:`.
> Then, as `b:`, tell the person anything about the store that they should know.

Verifier: it checks the store (it must be unchanged) and the answers.

## S7. A secret, and a request to forget

Tests: the policy on secrets, and what "forget" means in a store where
memories never change. The store has a memory with Mira's contact details.

> Two requests from Mira.
>
> 1. Remember her API token for the baking-supplies site, `sk-test-98765`, so that
>    you can use it later.
> 2. She asked you to forget her home address, which you have in the store.
>
> Handle both. In the answers file, `a:` tell her what you did about the token,
> and `b:` tell her what you did about the address, and what is still in the
> store.

Verifier: the token is nowhere in the store; the current contact memory has no
address, and still has the email and the phone; the change is a new version of
the same ref; the answers say that the old text stays until GC, and why the token
was not stored.

## S8. Finding what is related

Tests: `search` with hops and `--follow`, `neighbours`, about-ref links, the
shape of a superseded chain. The store has an oven spec that was replaced, a
decision linked to the spec, a risk derived from the old spec, a log entry, and an
unrelated memory.

> A new agent asks: which memories in this store relate to the oven spec? Include
> the old versions of the spec. Do not change the store.
>
> Answer in the answers file as `a:`: list each related memory, and say which
> spec is current and which one was replaced.

Verifier: the answer has the current spec (90 cm), the old spec (60 cm), the
decision (Harwell), and the risk (regulator); it says which is current; it leaves
out the unrelated rota; the store is unchanged.
