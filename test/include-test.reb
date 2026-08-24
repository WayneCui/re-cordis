REBOL []
do %../include/api.reb

passed: 0
failed: 0

assert: func [cond [logic!] label [string!]] [
    either cond [
        passed: passed + 1
        print rejoin ["PASS  " label]
    ][
        failed: failed + 1
        print rejoin ["FAIL  " label]
    ]
]

fixture: {
- id: skill-badge
  disabled: false

- id: skill-filesystem
  config:
    watch: false

- id: session-telemetry
  disabled: true
}

base: yaml-parse-entry-yaml fixture
assert equal? 3 length? base "parse three entries"
assert equal? false (entry-disabled? first base) "badge enabled"
assert equal? false (select entry-config-of second base 'watch) "filesystem watch false"
assert equal? true (entry-disabled? third base) "telemetry disabled in base"

patched: apply-entry-patches base reduce [
    make map! [id "skill-badge" disabled true]
    make map! compose [id "skill-filesystem" config (make map! [watch true])]
]
assert equal? true (entry-disabled? first patched) "patch disables badge"
assert true? (select entry-config-of second patched 'watch) "patch flips watch"

root-entry: make map! [id "root" group true]
put root-entry 'config copy []
group-base: reduce [root-entry]
inserted: apply-entry-patches group-base reduce [
    make map! compose [id "root" insert [(make map! [id "child" name "inner"])]]
]
sub: entry-config-of first inserted
assert equal? 1 length? sub "insert into group"
assert equal? "child" (entry-id-of (first sub)) "inserted child id"

nested-yaml: {
- id: llm
  name: llm
  intercept:
    agent-loop:
      max-steps: 2
}
nested-entries: yaml-parse-entry-yaml nested-yaml
ic: select first nested-entries 'intercept
assert map? ic "intercept parsed as map"
al: select ic 'agent-loop
assert map? al "intercept.agent-loop is a map"
assert equal? 2 select al 'max-steps "nested max-steps integer"

print rejoin ["^/==== include-test: " passed " passed, " failed " failed ===="]
if failed > 0 [quit 1]
