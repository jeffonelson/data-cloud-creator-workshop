# Data Cloud Creator Workshop

A hands-on workshop using AI coding agents and Google Cloud data tools to explore
a coffee shop expansion scenario.

Prepare your computer before starting. If you are attending a workshop or
Skills/Qwiklabs lab, use the Google Cloud project and access instructions
provided by your organizer; you do not need a personal billing account or free trial.

## Before the workshop: check your computer

Install these prerequisites using their official instructions:

- [Git](https://git-scm.com/downloads)
- [Google Cloud CLI](https://cloud.google.com/sdk/docs/install)
- [Python 3](https://www.python.org/downloads/), runnable as `python3` or `python`
- [Node.js 22.6 or newer and npm](https://nodejs.org/en/download) (current LTS recommended)
- One supported agent: [Codex CLI](https://developers.openai.com/codex/cli/),
  [Claude Code CLI](https://code.claude.com/docs/en/setup), or
  [Antigravity CLI](https://www.antigravity.google/docs/cli/install/)

On Windows, use Git Bash for the workshop commands. Install Python for that
terminal too; Google Cloud CLI's bundled Python may not be found by its Bash
launcher. You can install Python with:

```bash
winget install --id Python.Python.3.14 --exact --source winget --scope user
```

Close and reopen Git Bash after installation.

Clone the repository:

```bash
git clone https://github.com/jeffonelson/data-cloud-creator-workshop.git
cd data-cloud-creator-workshop
```

Then check local prerequisites:

```bash
./bin/doctor --preflight
```

This checks command availability, runs `python3` or `python` to confirm Python 3,
and checks the minimum Node.js version. A Windows app alias without a working
Python interpreter does not pass. It makes no cloud requests, starts no login
flow, and installs or configures nothing. No Google sign-in, project, or credit
card is required. Fix any reported failures
using the installation links and rerun until there are zero failures.

A passing preflight confirms local prerequisites only. Agent sign-in, Google
authentication, project permissions, plugins, and live tools are checked later.

## Connect your Google Cloud project

### 1. Sign in to Google Cloud

Replace `YOUR_USERNAME` with your Google account email address and
`YOUR_PROJECT_ID` with the project you will use. If you have an assigned lab
project, use the credentials supplied by the lab.

```bash
gcloud auth login YOUR_USERNAME --project=YOUR_PROJECT_ID --no-launch-browser
gcloud auth application-default login YOUR_USERNAME --project=YOUR_PROJECT_ID --no-launch-browser
```

When sign-in is needed, `--no-launch-browser` prints an authorization URL instead
of opening your default browser; paste it into the browser profile for that
account (or an Incognito/private window for temporary lab credentials), then
follow the terminal prompts.

Sign in to your chosen agent CLI if needed: `codex login`, `claude auth login`,
or `agy`. Agent sign-in is separate from Google Cloud sign-in. Workshop resources
are prepared by the organizers.

### 2. Configure and verify

`./bin/setup` checks access to your project and secrets, then installs
and configures the newest Data Agent Kit release for each supported agent on
your computer. It uses upstream DAK setup to select BigQuery, AlloyDB and Cloud Storage, with
notebook and visualization tools included by upstream. The plugin is
`dak@dak-marketplace`; the data servers are `dak-bigquery` and `dak-alloydb`.
Restart open agent sessions after setup.

Use your project ID and its AlloyDB region. For an assigned lab, use the values
supplied by the lab. Setup saves them for subsequent launches.
BigQuery uses its own dataset location; Cloud Run follows the selected region.

The selected project is saved in ignored `.workshop-state/project.env` and upstream's
non-secret `~/.config/data-agent-kit/config.json`. Setup does not change the global
gcloud project. A conflicting pre-existing DAK config or plugin installation stops
setup; resolve it with upstream DAK or the agent's plugin commands, then retry.
To move an installation owned by this checkout to a later release, run
`./bin/teardown` and then `./bin/setup PROJECT_ID --region REGION` again. Pre-existing installations are preserved.

```bash
./bin/setup YOUR_PROJECT_ID --region YOUR_REGION
```

`./bin/doctor` runs read-only checks for the required software, agent CLI login,
Google Cloud authentication, plugin installation, and MCP configuration.

```bash
./bin/doctor
```

Existing checkouts must rerun setup with --region once. Doctor verifies cluster
access in that region and checks that the agents' settings agree.

### 3. Launch one agent

Use a workshop launcher instead of running `codex`, `claude`, or `agy` directly so it
can load the workshop credentials and project settings before starting the agent.

```bash
./bin/workshop-codex -m gpt-6.1-terra -c model_reasoning_effort=medium
```

```bash
./bin/workshop-claude --model sonnet --effort medium
```

```bash
./bin/workshop-antigravity --model gemini-3.8-flash-medium
```

These commands start the models we tested for this lab. To try a more capable
model in Codex CLI or Claude Code CLI, run `/model` in your session.

All three CLI launchers default `DO_NOT_TRACK=1` for the agent session and its
child processes. This opts out of DAK telemetry and avoids its Windows console
pop-ups. An explicitly set `DO_NOT_TRACK` value is preserved.

Trust the repository when prompted. Keep this session open for the entire lab.

## Connectivity check

First, run `/mcp` in the agent and confirm that the Developer Knowledge, Maps
Grounding Lite, Cloud Run, BigQuery, AlloyDB, and Cloud Storage MCP servers are loaded.
Cloud Storage comes from the Data Agent Kit and uses your Google Cloud credentials.

Then paste the following prompt into the same agent session and run it:

```text
Use the MCP tools for these checks. Make one successful read-only call to each service:

1. Developer Knowledge: retrieve the official BigQuery row-level security documentation.
2. Maps: find two coffee shops near the de Young Museum in Golden Gate Park and include their Google Maps links.
3. BigQuery: list datasets in project PROJECT_ID.
4. AlloyDB: list clusters in REGION.

Return a four-row PASS/FAIL table. Empty BigQuery or AlloyDB results count as PASS.

For the rest of this session, run the analysis yourself with these tools and show me the results.
```

Replace `PROJECT_ID` and `REGION` with the values you used for `./bin/setup`.

## Data landscape

[![Preview of Charlie's Coffee data landscape](assets/data-landscape-preview.png)](https://jeffonelson.github.io/data-cloud-creator-workshop/data-landscape.html)

[Open the interactive data landscape](https://jeffonelson.github.io/data-cloud-creator-workshop/data-landscape.html)
to explore the tables, documents, and relationships between them.

The broker's documents are available in
`gs://PROJECT_ID-charlies-documents/leases/`, one PDF per `candidate_sites.site_id`.
Use your setup-selected project ID. The documents are available throughout the lab.
Developer Knowledge provides official Google Cloud documentation; Maps Grounding
Lite supplies current place and route context with Google Maps attribution.

## Charlie's expansion scenario

> **🎯 Your north star**
>
> Recommend Charlie’s next San Francisco location and be prepared to defend it. The prompts below are suggestions, not a required sequence. Ask your own questions and follow whichever evidence interests you.

> **Tip:** If your agent hands you a notebook or script to run instead of results, reply: `Run it yourself with the MCP tools and show me the results.`

Charlie's Coffee operates six San Francisco stores and is choosing where to open
next. Run the suggested prompts for the shortest path through the scenario, then
choose any optional follow-ups that match your interests and available time.
Continue in the same agent session so later prompts can build on earlier findings.

The suggested path uses **Developer Knowledge → business data → a shortlist →
Google Maps → broker documents**. Record your recommendation before the
facilitator calls the room together. These are fictional business records; Maps
provides real-world context around the scenario's representative locations.

### Frame the decision

#### Suggested prompt

```text
According to the official Google Cloud documentation, why might AlloyDB be a
better home for live inventory than BigQuery, and when would that choice stop
making sense?
```

#### Optional follow-ups

```text
How can we analyze AlloyDB and BigQuery together without first building another ETL pipeline? Use the official Google Cloud documentation and cite the documents you use.
```

```text
Charlie's wants to open a seventh San Francisco store. Help me make a recommendation we can defend. Before running any analysis, what evidence would you want, and where would you expect to find it?
```

### Investigate unmet demand

#### Suggested prompt

```text
Look across our cloud databases: where is Charlie's inventory failing to meet customer demand?
```

#### Optional follow-ups

```text
Can stock-movement history explain how those shortages developed?
```

### Check the customer evidence

#### Suggested prompt

```text
Use BigQuery AI to extract availability complaints from customer reviews.
Do they corroborate the live inventory?
```

#### Optional follow-ups

```text
Can you combine the operational and analytical evidence in one analysis without copying the AlloyDB data into BigQuery first?
```

```text
Which complaints match specific store/product pairs, and which are ambiguous?
```

### Choose a new location

#### Suggested prompt

```text
Use BigQuery AI.FORECAST to forecast six months of candidate-market demand.
Which site looks best after estimating store revenue and accounting for rent?
```

#### Optional follow-ups

```text
What separates Charlie's strongest store markets from its weakest ones?
```

```text
How did you translate market demand into store revenue? Check your assumptions
against Charlie's existing stores.
```

```text
What assumptions have the most influence on the ranking, and what would need to change for the runner-up to win?
```

### Test the recommendation in the real world

#### Suggested prompt

```text
Use Maps to stress-test your recommended SF expansion spot. What nearby evidence
strengthens or weakens the case? Include the Google Maps source link
immediately after every place-based claim.
```

#### Optional follow-ups

```text
Does nearby coffee competition indicate saturation, or does it validate demand?
```

```text
Which nearby residential areas could expand Charlie’s delivery reach through DoorDash or Uber Eats? Use Maps to compare driving times from the site.
```

```text
Which nearby residential buildings and neighborhood anchors are within a 10-minute walk of the site and could contribute launch-day foot traffic?
```

### Check the broker's lease terms

Before locking in your recommendation, there is one more source of evidence: the commercial broker has uploaded draft lease PDFs to Cloud Storage for the candidate storefronts.

#### Suggested prompt

```text
There are draft lease PDFs from the broker in Cloud Storage. Read them with the
Cloud Storage MCP, then check the lease terms for your recommended site and top
alternatives. Do the actual rent, recurring charges, or lease conditions change
your recommendation?
```

#### Optional follow-ups

```text
Cite the document, page, and section for the most important lease findings.
Are any charges counted twice or missing from candidate_sites?
```

```text
What should we ask the broker to clarify or renegotiate before signing?
```

If PDF reading fails, tell the facilitator and run `./bin/doctor`; a successful
listing alone does not prove the agent can read a PDF. Do not invent terms or
treat missing costs as zero.

> **⏸️ Facilitator checkpoint**
>
> Write down your recommended site. Did the lease terms change it? Continue
> exploring until the facilitator calls the room back together.

## Further exploration

The remaining activities are for extra workshop time or continued exploration afterward.

### Make it local

Want to explore somewhere you know? Bring Charlie's to your own spot. Replace
`[LOCATION]` with anywhere in the world you'd like to explore; include the country
if the name could be ambiguous. San Francisco's numbers remain business benchmarks.
Skip this section to continue with your San Francisco recommendation.

#### Suggested prompt

```text
What if Charlie's expanded into [LOCATION]? Use Maps to suggest three areas
worth exploring, informed by what we learned from its San Francisco stores.
```

#### Follow-up

```text
Which area looks most promising, and what would we need to verify?
Pick a specific map anchor for a hypothetical store to explore next.
```

### Plan the launch

#### Suggested prompt

```text
Design a launch-week plan for the recommended site using everything we have learned.
```

#### Optional follow-ups

```text
If we held an outdoor launch event at the recommended site this weekend, what do the hourly and daily weather forecasts suggest, and how should we adjust the plan?
```

```text
Which nearby gyms and coworking spaces should we approach as launch partners?
```

```text
What stock problems should we avoid repeating at launch?
```

```text
Revise the launch plan based on what you discovered.
```

### Visualize and share (optional)

#### Suggested prompt

```text
Build a good-looking, interactive single-page dashboard of Charlie's sales,
inventory, and market demand as one HTML file in this folder, using a snapshot
of the data. Highlight the most interesting findings.
```

#### Optional follow-ups

```text
Audit the dashboard's numbers and labels against the source data.
```

```text
Deploy the dashboard as a public service with the Cloud Run MCP. Return the live URL.
```


## Uninstall

Exit the agent, then run:

```bash
./bin/teardown
```

This removes workshop-installed agent plugins and local workshop state. It does
not change Google Cloud or delete this repository.

## Disclaimer

This is a project intended for demonstration and workshop purposes only. It is
not intended for use in a production environment. This repository is not an
officially supported Google product.
