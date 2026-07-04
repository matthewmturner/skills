/**
 * System Prompt Sources Extension
 *
 * Displays a breakdown of all system prompt sources and their approximate
 * sizes (chars, words) when pi first opens. Shows the total
 * baseline system prompt size.
 *
 * Features:
 * - Lists each source with char count, word count, and percentage
 * - Shows the final assembled system prompt size
 * - Shows on startup (session_start)
 * - Cleans up on session shutdown
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

/** Estimate word count from text */
function wordCount(text: string): number {
  return text.trim() === "" ? 0 : text.trim().split(/\s+/).length;
}

/** Estimate token count approximation: ~4 chars per token (rough avg for English) */
function approximateTokens(text: string): number {
  return text.length > 0 ? Math.ceil(text.length / 4) : 0;
}

interface SourceInfo {
  name: string;
  chars: number;
  words: number;
  tokens: number;
}

/**
 * Compute source breakdown from the assembled system prompt string.
 * Parses known structural markers to identify sections.
 * Used at session_start when systemPromptOptions is not available.
 */
function computeSourcesFromPrompt(
  systemPrompt: string,
): SourceInfo[] {
  const sources: SourceInfo[] = [];
  let remaining = systemPrompt;

  // 1. Extract <available_skills> section
  const skillsMatch = remaining.match(/(<available_skills>.*?<\/available_skills>)/s);
  if (skillsMatch) {
    const skillBlock = skillsMatch[1];
    sources.push({
      name: "Skills",
      chars: skillBlock.length,
      words: wordCount(skillBlock),
      tokens: approximateTokens(skillBlock),
    });
    remaining = remaining.slice(0, skillsMatch.index!) + remaining.slice(skillsMatch.index! + skillBlock.length);
  }

  // 2. Extract <project_instructions> section
  const projMatch = remaining.match(/(<project_instructions>.*?<\/project_instructions>)/s);
  if (projMatch) {
    const projBlock = projMatch[1];
    sources.push({
      name: "Project context",
      chars: projBlock.length,
      words: wordCount(projBlock),
      tokens: approximateTokens(projBlock),
    });
    remaining = remaining.slice(0, projMatch.index!) + remaining.slice(projMatch.index! + projBlock.length);
  }

  // 3. Extract "Available tools:" section
  const toolsMatch = remaining.match(/(Available tools:.*?)(?:\n\n|Current date:|$)/s);
  if (toolsMatch) {
    const toolsBlock = toolsMatch[1].trimEnd();
    sources.push({
      name: "Available tools",
      chars: toolsBlock.length,
      words: wordCount(toolsBlock),
      tokens: approximateTokens(toolsBlock),
    });
    remaining = remaining.slice(0, toolsMatch.index!) + remaining.slice(toolsMatch.index! + toolsMatch[0].length);
  }

  // 4. Extract "Guidelines:" section
  const guidelinesMatch = remaining.match(/(Guidelines:.*?)(?:\n\n|Current date:|$)/s);
  if (guidelinesMatch) {
    const guidelinesBlock = guidelinesMatch[1].trimEnd();
    sources.push({
      name: "Guidelines",
      chars: guidelinesBlock.length,
      words: wordCount(guidelinesBlock),
      tokens: approximateTokens(guidelinesBlock),
    });
    remaining = remaining.slice(0, guidelinesMatch.index!) + remaining.slice(guidelinesMatch.index! + guidelinesMatch[0].length);
  }

  // 5. Extract footer
  const footerMatch = remaining.match(/(Current date:.*$)/s);
  if (footerMatch) {
    const footerBlock = footerMatch[1].trimEnd();
    sources.push({
      name: "Footer (date + working directory)",
      chars: footerBlock.length,
      words: wordCount(footerBlock),
      tokens: approximateTokens(footerBlock),
    });
    remaining = remaining.slice(0, footerMatch.index!) + remaining.slice(footerMatch.index! + footerMatch[0].length);
  }

  // 6. Everything else = base prompt
  const baseText = remaining.trim();
  if (baseText.length > 0) {
    sources.push({
      name: "Base prompt",
      chars: baseText.length,
      words: wordCount(baseText),
      tokens: approximateTokens(baseText),
    });
  }

  return sources;
}

/** Format a SourceInfo as a display line */
function formatSource(src: SourceInfo, totalChars: number): string {
  const pct = totalChars > 0 ? `${Math.round((src.chars / totalChars) * 100)}%` : "";
  return `  ${src.name}: ${src.chars.toLocaleString()} chars, ${src.words.toLocaleString()} words, ~${src.tokens.toLocaleString()} tokens (${pct})`;
}

export default function (pi: ExtensionAPI) {
  const widgetName = "prompt-sources";
  const statusName = "prompt-sources";

  let shown = false;

  pi.on("session_start", async (_event, ctx) => {
    shown = false;
    const systemPrompt = ctx.getSystemPrompt();
    if (!systemPrompt || systemPrompt.length === 0) return;

    const sources = computeSourcesFromPrompt(systemPrompt);
    const totalChars = sources.reduce((sum, s) => sum + s.chars, 0);
    const totalWords = sources.reduce((sum, s) => sum + s.words, 0);
    const totalTokens = sources.reduce((sum, s) => sum + s.tokens, 0);

    const lines: string[] = [];
    lines.push(
      ctx.ui.theme.bold(
        `📋 System Prompt Sources (${totalChars.toLocaleString()} chars)`,
      ),
      "",
    );

    for (const src of sources) {
      lines.push(formatSource(src, totalChars));
    }

    lines.push("");
    lines.push(
      ctx.ui.theme.bold(
        `Total: ${totalChars.toLocaleString()} chars / ${totalWords.toLocaleString()} words / ~${totalTokens.toLocaleString()} tokens\n\n`,
      ),
    );

    ctx.ui.setWidget(widgetName, lines);
    ctx.ui.setStatus(
      statusName,
      ctx.ui.theme.fg("muted", `system prompt: ${systemPrompt.length.toLocaleString()} chars`),
    );
  });

  pi.on("before_agent_start", async (_event, ctx) => {
    if (shown) return;
    shown = true;
    ctx.ui.setWidget(widgetName, undefined);
  });

  pi.on("session_shutdown", (_event, ctx) => {
    ctx.ui.setWidget(widgetName, undefined);
    ctx.ui.setStatus(statusName, undefined);
  });
}
