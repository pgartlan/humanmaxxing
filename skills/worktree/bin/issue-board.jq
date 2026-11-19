# issue-board.jq — turns worktree-issue.sh's GraphQL answer into lines the script reads in bash, fields separated
# by the ASCII unit separator (0x1f), so an empty field stays a field.
# Kept in its own file so the tests can run it against a recorded answer. Passed to `gh api graphql --jq`.
#   STATE <state> <assignee logins, comma-separated>
#   ITEM  <project owner> <project number> <item id> <project id> <status field id> <current status name>
#   OPT   <project owner> <project number> <option name> <option id>
.data.repository.issue as $i
| if $i == null then error("no such issue") else
    (["STATE", $i.state, ([$i.assignees.nodes[].login] | join(","))] | map(. // "" | tostring) | join("\u001f")),
    (($i.projectItems.nodes // [])[] | . as $n
      | (["ITEM", $n.project.owner.login, ($n.project.number | tostring), $n.id, $n.project.id,
          ($n.project.field.id // ""), ($n.fieldValueByName.name // "")] | map(. // "" | tostring) | join("\u001f")),
        (($n.project.field.options // [])[]
          | ["OPT", $n.project.owner.login, ($n.project.number | tostring), .name, .id] | map(. // "" | tostring) | join("\u001f")))
  end
