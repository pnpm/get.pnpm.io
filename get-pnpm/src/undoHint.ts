/**
 * How to take back what `pnpm setup` just did under `pnpmHome`, printed once
 * it succeeds. `pnpm setup` names the shell config file it changed and prints
 * the lines it added, so the hint points back at that output rather than
 * guessing the file again. When setup cannot tell which file to change, it
 * changes none, so the hint does not assume one was named.
 */
export function renderUndoHint (pnpmHome: string, platform: NodeJS.Platform = process.platform): string {
  const undo = platform === 'win32'
    ? `delete ${pnpmHome}, then remove the PNPM_HOME variable and the Path entry pnpm setup added from your user environment variables.`
    : `delete ${pnpmHome}. If pnpm setup named a shell config file above, also remove the lines it added there.`
  return `To uninstall, ${undo}\nSee https://pnpm.io/uninstall`
}
