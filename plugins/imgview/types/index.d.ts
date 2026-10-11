/** The picture the pane shows: where it is, how large, and how it is drawn. */
export type Shown = {
  /** The file as resolved: absolute where the file system said where it lands. */
  path: string;
  /** Its last path segment, the pane's caption. */
  name: string;
  /** Pixels across. */
  width: number;
  /** Pixels down. */
  height: number;
  /** Last modification, milliseconds since the epoch: a change redraws. */
  mtimeMs: number;
  /** `pixels`: the terminal draws the file itself; `cells`: quarter blocks. */
  mode: "cells" | "pixels";
  /** In `pixels` mode, the absolute path of a PNG the terminal reads. */
  png?: string;
  /** True when the mod wrote that PNG itself, so it is the mod's to remove. */
  isPngTemporary?: true;
};

declare module "claude-code" {
  interface PluginState {
    imgview: {
      shown: Shown | null;
      /** The temporary files the mod made and has not removed, by path. */
      temps: readonly string[];
    };
  }
}
