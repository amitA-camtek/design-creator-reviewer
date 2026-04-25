Save the most recent assistant response in this conversation to a markdown file.

**Usage**: `/save-output <file-path>`

**Steps**:
1. Identify the most recent assistant response in this conversation (the response immediately before this command was invoked).
2. Write its full content to the file path provided by the user.
3. If the file already exists, append the content with a `---` separator rather than overwriting.
4. If no file path is provided, write to `saved-output-$CURRENT_DATE.md` in the current working directory.
5. Confirm: "Saved to `<file-path>`."

**Examples**:
- `/save-output output/security-findings.md` — saves last response to that file
- `/save-output` — saves to `saved-output-2026-04-25.md` in the current directory