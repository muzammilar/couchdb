# Contributing to CouchDB

Please take a moment to review this document in order to make the contribution
process easy and effective for everyone involved.

Following these guidelines helps to communicate that you respect the time of
the developers managing and developing this open source project. In return,
they should reciprocate that respect in addressing your issue, assessing
changes, and helping you finalize your pull requests.

Contributions to CouchDB are governed by our [Code of Conduct][6] and a set of
[Project Bylaws][7]. Come join us!

## Using the issue tracker

First things first: **Do NOT report security vulnerabilities in public issues!**
Please disclose responsibly by letting [the Apache CouchDB Security team][11]
know upfront. We will assess the issue as soon as possible on a best-effort
basis and will give you an estimate for when we have a fix and release available
for an eventual public disclosure.

The [GitHub issue tracker][#gh_issues] is the preferred channel for
[bug reports](#bug-reports), [features requests](#feature-requests)
and [submitting pull requests](#pull-requests), but please respect
the following restrictions:

* Please **do not** use the issue tracker for personal support requests. Use
  [CouchDB Chat][8] instead. Alternately, help us to help more people by
  using our publicly archived [user][1] or [developer][5] mailing lists.

* Please **do not** derail or troll issues. Keep the discussion on topic and
  respect the opinions of others.

## Bug reports

A bug is a _demonstrable problem_ that is caused by the code in our
repositories.  Good bug reports are extremely helpful - thank you!

Guidelines for bug reports:

1. **Use the GitHub issue search** &mdash; check if the issue has already been
   reported.

2. **Check if the issue has been fixed** &mdash; try to reproduce it using the
   latest `main` or `next` branch in the repository.

3. **Isolate the problem** &mdash; ideally create a reduced test case.

A good bug report shouldn't leave others needing to chase you up for more
information. Please try to be as detailed as possible in your report. What is
your environment? What steps will reproduce the issue? What OS experiences the
problem? What would you expect to be the outcome? All these details will help
people to fix any potential bugs. Our issue template will help you include all
of the relevant detail.

Example:

> Short and descriptive example bug report title
>
> A summary of the issue and the browser/OS environment in which it occurs. If
> suitable, include the steps required to reproduce the bug.
>
> 1. This is the first step
> 2. This is the second step
> 3. Further steps, etc.
>
> `<url>` - a link to the reduced test case
>
> Any other information you want to share that is relevant to the issue being
> reported. This might include the lines of code that you have identified as
> causing the bug, and potential solutions (and your opinions on their
> merits).

## Feature requests

Feature requests are welcome. But take a moment to find out whether your idea
fits with the scope and aims of the project. It's up to *you* to make a strong
case to convince the project's developers of the merits of this feature. Please
provide as much detail and context as possible.

## Pull requests

Good pull requests - patches, improvements, new features - are a fantastic
help. They should remain focused in scope and avoid containing unrelated
commits.

**Please ask first** before embarking on any significant pull request (e.g.
implementing features, refactoring code), otherwise you risk spending a lot of
time working on something that the project's developers might not want to merge
into the project. You can talk with the community on our
[developer mailing list][5].  We're always open to suggestions and will get
back to you as soon as we can!

### CouchDB commit message conventions

A well-crafted Git commit message is the best way to communicate context about a
change to other developers working on that project, and indeed, to your future self.

Commit messages can adequately communicate why a change was made, and understanding
that makes development and collaboration more efficient.

Here's a great template of a good commit message

```
Capitalized, short (50 chars or less) summary

More detailed explanatory text, if necessary.  Wrap it to about 72
characters or so.  In some contexts, the first line is treated as the
subject of an email and the rest of the text as the body.  The blank
line separating the summary from the body is critical (unless you omit
the body entirely); tools like rebase can get confused if you run the
two together.

Write your commit message in the imperative: "Fix bug" and not "Fixed bug"
or "Fixes bug."  This convention matches up with commit messages generated
by commands like git merge and git revert.

Further paragraphs come after blank lines.

- Bullet points are okay, too

- Typically a hyphen or asterisk is used for the bullet, followed by a
  single space, with blank lines in between, but conventions vary here

- Use a hanging indent
```

### For new Contributors

If you never created a pull request before, welcome :tada: :smile:
[Here is a great tutorial][12] on how to send one :)

1. [Fork][13] the project, clone your fork,
   and configure the remotes:

   ```bash
   # Clone your fork of the repo into the current directory
   git clone https://github.com/<your-username>/<repo-name>
   # Navigate to the newly cloned directory
   cd <repo-name>
   # Assign the original repo to a remote called "upstream"
   git remote add upstream https://github.com/apache/<repo-name>
   ```

2. If you cloned a while ago, get the latest changes from upstream:

   ```bash
   git checkout main
   git pull upstream main
   ```

3. Create a new topic branch (off the main project development branch) to
   contain your feature, change, or fix:

   ```bash
   git checkout -b <topic-branch-name>
   ```

4. Make sure to update, or add to the tests when appropriate. Patches and
   features will not be accepted without tests. Run `make check` to check that
   all tests pass after you've made changes. Look for a `Testing` section in
   the project’s README for more information.

5. If you added or changed a feature, make sure to document it accordingly in
   the [CouchDB documentation][14]
   repository.

6. Push your topic branch up to your fork:

   ```bash
   git push origin <topic-branch-name>
   ```

8. [Open a Pull Request][15]
   with a clear title and description.

### For Apache CouchDB Committers

1. Be sure to set up [GitHub two-factor authentication][16],
   then [link your Apache account to your GitHub account][17].
   You will need to wait about 30 minutes after completing this process
   for it to complete. Follow the instructions in the organisational
   invite email you receive. Alternately, you can use the Apache mirror
   of the repository at `https://gitbox.apache.org/repos/asf/couchdb.git`
   if you do not agree to the GitHub Terms of Service.

2. Clone the repo and create a branch.

   ```bash
   git clone https://github.com/apache/couchdb
   # or git clone https://gitbox.apache.org/repos/asf/couchdb.git
   cd couchdb
   git checkout -b <topic-branch-name>
   ```

3. Make sure to update, or add to the tests when appropriate. Patches and
   features will not be accepted without tests. Run `make check` to check that
   all tests pass after you've made changes. Look for a `Testing` section in
   the project’s README for more information.

4. If you added or changed a feature, make sure to document it accordingly in
   the [documentation][14] directory.

5. Push your topic branch up to our repo

   ```bash
   git push origin <topic-branch-name>
   ```

6. Open a Pull Request using your branch with a clear title and description.
   Please also add any appropriate labels to the pull request for clarity.

Optionally, you can help us with these things. But don’t worry if they are too
complicated, we can help you out and teach you as we go :)

1. Update your branch to the latest changes in the upstream main branch. You
   can do that locally with

   ```bash
   git pull --rebase upstream main
   ```

   Afterwards force push your changes to your remote feature branch.

2. Once a pull request is good to go, you can tidy up your commit messages using
   Git's [interactive rebase][18].

**IMPORTANT**: By submitting a patch, you agree to license your work under the
Apache License, per your signed Apache CLA.

## Triagers

Apache CouchDB committers who have completed the GitHub account linking
process may triage issues. This helps to speed up releases and minimises both
user and developer pain in working through our backlog.

Briefly, to triage an issue, review the report, validate that it is an actual
issue (reproducing if possible), and add one or more labels. We have a
[summary of our label taxonomy][19] for your reference.

If you are not an official committer, please reach out to our [mailing list][5]
or [chat][8] to learn how you can assist with triaging indirectly.

## Maintainers

If you have commit access, please follow this process for merging patches and cutting
new releases.

### Reviewing changes

1. Check that a change is within the scope and philosophy of the component.
2. Check that a change has any necessary tests.
3. Check that a change has any necessary documentation.
4. If there is anything you don’t like, leave a comment below the respective
   lines and submit a "Request changes" review. Repeat until everything has
   been addressed.
5. If you are not sure about something, mention specific people for help in a
   comment.
6. If there is only a tiny change left before you can merge it and you think
   it’s best to fix it yourself, you can directly commit to the author’s fork.
   Leave a comment about it so the author and others will know.
7. Once everything looks good, add an "Approve" review. Don’t forget to say
   something nice 👏🐶💖✨
8. If the commit messages follow [our conventions](#couchdb-commit-message-conventions)

   1. If the pull request fixes one or more open issues, please include the
      text "Fixes #472" or "Fixes apache/couchdb#472".
   2. Use the "Rebase and merge" button to merge the pull request.
   3. Done! You are awesome! Thanks so much for your help 🤗

9. If the commit messages _do not_ follow our conventions

   1. Use the "squash and merge" button to clean up the commits and merge at
      the same time: ✨🎩
   2. If the pull request fixes one or more open issues, please include the
      text "Fixes #472" or "Fixes apache/couchdb#472".

Sometimes there might be a good reason to merge changes locally. The process
looks like this:

### Reviewing and merging changes locally

```
git checkout main # or the main branch configured on github
git pull # get latest changes
git checkout feature-branch # replace name with your branch
git rebase main
git checkout main
git merge feature-branch # replace name with your branch
git push
```

When merging PRs from forked repositories, we recommend you install the
[hub][#gh_hub] command line tools.

This allows you to do:

```
hub checkout link-to-pull-request
```

meaning that you will automatically check out the branch for the pull request,
without needing any other steps like setting git upstreams! :sparkles:

## Artificial Intelligence and Large Language Models Contributions Policy

The CouchDB project has a long-standing focus on license compatibility, and
appropriate attribution of source code. AI and LLMs, by their nature, are unable
to provide the necessary assurance, that the generated material is compatible
with the Apache 2 license, or that the material has been appropriately
attributed to the original authors.

Thus, it is expressly forbidden to contribute material generated by AI, LLMs,
and similar technologies, to the CouchDB project. This includes, but is not
limited to, source code, documentation, commit messages, or any other areas of
the project.

## Thanks

Special thanks to [Hoodie][#gh_hoodie] for the great
CONTRIBUTING.md template.

A big thanks to [Robert Painsi][9] and [Bolaji Ayodeji][10] for
some commit message conventions.

[1]: https://mail-archives.apache.org/mod_mbox/couchdb-user
[5]: https://mail-archives.apache.org/mod_mbox/couchdb-dev
[6]: https://couchdb.apache.org/conduct.html
[7]: https://couchdb.apache.org/bylaws.html
[8]: https://couchdb.apache.org/#chat
[9]: https://gist.github.com/robertpainsi/b632364184e70900af4ab688decf6f53
[10]: https://www.freecodecamp.org/news/writing-good-commit-messages-a-practical-guide
[11]: mailto:security@couchdb.apache.org?subject=Security
[12]: https://egghead.io/courses/how-to-contribute-to-an-open-source-project-on-github
[13]: https://help.github.com/fork-a-repo
[14]: https://github.com/apache/couchdb/tree/main/src/docs
[15]: https://help.github.com/articles/using-pull-requests
[16]: https://help.github.com/articles/about-two-factor-authentication
[17]: https://gitbox.apache.org/setup
[18]: https://help.github.com/articles/interactive-rebase
[19]: https://github.com/apache/couchdb/issues/499

[#gh_issues]: https://github.com/apache/couchdb/issues
[#gh_hoodie]: https://github.com/hoodiehq/hoodie
[#gh_hub]: https://hub.github.com
