//! Read standard Agent editors and menus without treating terminal output as chat history.
use crate::*;
#[derive(Clone, Default, Debug)]
pub(crate) struct Line {
    pub(crate) text: String,
    pub(crate) dim: Vec<bool>,
    pub(crate) inverse: Vec<bool>,
}
fn line(raw: &str, style: &mut (bool, bool)) -> Line {
    let mut parsed = Line::default();
    let (mut dim, mut inverse) = *style;
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' && chars.peek() == Some(&'[') {
            chars.next();
            let mut codes = String::new();
            for next in chars.by_ref() {
                if ('@'..='~').contains(&next) {
                    if next == 'm' {
                        let values: Vec<u16> =
                            codes.split(';').map(|c| c.parse().unwrap_or(0)).collect();
                        let mut i = 0;
                        while i < values.len() {
                            match values[i] {
                                0 => {
                                    dim = false;
                                    inverse = false;
                                }
                                2 => dim = true,
                                7 => inverse = true,
                                22 => dim = false,
                                27 => inverse = false,
                                38 | 48 | 58 => {
                                    i += match values.get(i + 1) {
                                        Some(2) => 4,
                                        Some(5) => 2,
                                        _ => 0,
                                    };
                                }
                                _ => {}
                            }
                            i += 1;
                        }
                    }
                    break;
                } else {
                    codes.push(next);
                }
            }
        } else {
            parsed.text.push(c);
            parsed.dim.push(dim);
            parsed.inverse.push(inverse);
        }
    }
    *style = (dim, inverse);
    parsed
}
#[derive(Clone)]
pub struct Frame {
    pub(crate) lines: Vec<Line>,
    pub cursor_x: usize,
    pub cursor_y: usize,
    pub(crate) cursor_visible: bool,
}
pub use crate::interactions::Menu;
impl Frame {
    pub fn parse(raw: &str, cursor_x: usize, cursor_y: usize, cursor_visible: bool) -> Self {
        let mut style = (false, false);
        Self {
            lines: raw.lines().map(|raw| line(raw, &mut style)).collect(),
            cursor_x,
            cursor_y,
            cursor_visible,
        }
    }
    pub fn editor_ready(&self, provider: &str) -> bool {
        if crate::interactions::blocks_editor(self, provider) {
            return false;
        }
        let Some(line) = self.lines.get(self.cursor_y) else {
            return false;
        };
        let border = |line: &Line| {
            let s = line.text.trim();
            s.starts_with('─') && s.ends_with('─') && s.chars().filter(|c| *c == '─').count() >= 8
        };
        let trimmed = line.text.trim_start();
        if provider == "pi" {
            let lower_border = |line: &Line| {
                let s = line.text.trim();
                // pi-lens/Vim appends its mode to the lower editor border.
                // Only INSERT is writable; NORMAL/VISUAL are not text editors.
                let suffix = s.trim_start_matches('─').trim();
                (border(line) && !s.contains("NORMAL") && !s.contains("VISUAL"))
                    || (s.chars().take_while(|c| *c == '─').count() >= 8 && suffix == "INSERT")
            };
            let empty = line.text.trim().is_empty()
                || (self.cursor_x == 0
                    && line
                        .text
                        .chars()
                        .enumerate()
                        .all(|(i, c)| c.is_whitespace() || line.dim[i]));
            // Pi defaults to a reverse-video software cursor, while still
            // positioning the hidden hardware cursor at the focused editor.
            let focused_cursor =
                self.cursor_visible || line.inverse.get(self.cursor_x).copied().unwrap_or(false);
            return focused_cursor
                && empty
                && self.cursor_y > 0
                && self.lines.get(self.cursor_y - 1).is_some_and(border)
                && self.lines.get(self.cursor_y + 1).is_some_and(lower_border)
                && self.menu("pi", 0).is_none();
        }
        let prompt = match provider {
            "codex" => '›',
            "claude" => '❯',
            _ => return false,
        };
        if !trimmed.starts_with(prompt) {
            return false;
        }
        let bordered_claude_editor = provider == "claude"
            && self.cursor_y > 0
            && self.cursor_x == 2
            && self.lines.get(self.cursor_y - 1).is_some_and(border)
            && self.lines.get(self.cursor_y + 1).is_some_and(border);
        if !self.cursor_visible && !bordered_claude_editor {
            return false;
        }
        if provider == "claude" {
            let mut footer = self.lines.iter().skip(self.cursor_y + 2).take(4);
            if footer.any(|line| {
                let text = line.text.split_whitespace().collect::<Vec<_>>().join(" ");
                text.contains("-- NORMAL --") || text.contains("-- VISUAL --")
            }) || self.menu("claude", 0).is_some()
            {
                return false;
            }
        }
        if trimmed.trim() == prompt.to_string() {
            return true;
        }
        let prefix = line.text.chars().take_while(|c| c.is_whitespace()).count() + 1;
        let remaining: Vec<_> = line
            .text
            .chars()
            .enumerate()
            .skip(prefix)
            .filter(|(_, c)| !c.is_whitespace())
            .collect();
        // A rendered placeholder is dim, and the hardware cursor stays before its first character.
        // A real draft (including a draft with its cursor at Home) is not dim and must be preserved.
        remaining.first().is_some_and(|(first, _)| {
            self.cursor_x == *first && remaining.iter().all(|(i, _)| line.dim[*i])
        })
    }
    pub fn menu(&self, provider: &str, pid: u32) -> Option<Menu> {
        crate::interactions::detect(self, provider, pid)
    }
}
pub async fn capture(app: &App, id: &str) -> Result<Frame> {
    let metadata = tmux(
        app,
        &[
            "display-message",
            "-p",
            "-t",
            id,
            "#{cursor_x} #{cursor_y} #{cursor_flag}",
        ],
    )
    .await?;
    let fields: Vec<_> = metadata.split_whitespace().collect();
    if fields.len() != 3 {
        return Err(internal("Unable to inspect Agent editor"));
    }
    let raw = tmux(app, &["capture-pane", "-p", "-e", "-t", id]).await?;
    Ok(Frame::parse(
        &raw,
        fields[0].parse().map_err(internal)?,
        fields[1].parse().map_err(internal)?,
        fields[2] == "1",
    ))
}
pub fn commands(provider: &str) -> serde_json::Value {
    crate::interactions::commands(provider)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn codex_dim_placeholder_is_empty_but_drafts_and_rgb_backgrounds_are_not() {
        assert!(
            Frame::parse(
                "\u{1b}[1m›\u{1b}[0m \u{1b}[48;2;42;45;50m\u{1b}[2mAsk anything\u{1b}[0m",
                2,
                0,
                true
            )
            .editor_ready("codex")
        );
        assert!(!Frame::parse("› real draft", 2, 0, true).editor_ready("codex"));
        assert!(
            !Frame::parse("› \u{1b}[48;2;42;45;50mreal draft", 2, 0, true).editor_ready("codex")
        );
        assert!(!Frame::parse("› \u{1b}[2mplaceholder", 2, 0, false).editor_ready("codex"));
    }
    #[test]
    fn claude_and_pi_placeholders_keep_existing_drafts_protected() {
        assert!(Frame::parse("❯ \u{1b}[2mTry a task", 2, 0, true).editor_ready("claude"));
        assert!(!Frame::parse("❯ Mac draft", 2, 0, true).editor_ready("claude"));
        assert!(
            Frame::parse(
                "── thinking ────────\n\u{1b}[2mEnter a message\n───────────────────",
                0,
                1,
                true
            )
            .editor_ready("pi")
        );
        assert!(
            Frame::parse(
                "───────────────────\n\u{1b}[0;7m \u{1b}[0m\n───────────────────",
                0,
                1,
                false
            )
            .editor_ready("pi")
        );
        assert!(
            !Frame::parse("───────────────────\n \n───────────────────", 0, 1, false)
                .editor_ready("pi")
        );
        assert!(
            !Frame::parse(
                "───────────────────\n\u{1b}[7mdraft\u{1b}[27m\n───────────────────",
                0,
                1,
                false
            )
            .editor_ready("pi")
        );
        assert!(
            !Frame::parse(
                "───────────────────\nMac draft\n───────────────────",
                0,
                1,
                true
            )
            .editor_ready("pi")
        );
    }
    #[test]
    fn claude_hidden_cursor_in_bordered_insert_editor_is_ready() {
        let raw = "\u{1b}[38;5;244m────────────────────\n\u{1b}[39m❯\u{a0}\n\u{1b}[38;5;244m────────────────────\nstatus\n-- INSERT -- auto mode on";
        assert!(Frame::parse(raw, 2, 1, false).editor_ready("claude"));
        assert!(
            !Frame::parse(&raw.replace("INSERT", "NORMAL"), 2, 1, false).editor_ready("claude")
        );
        assert!(!Frame::parse(&raw.replace("INSERT", "VISUAL"), 2, 1, true).editor_ready("claude"));
        assert!(
            !Frame::parse(&raw.replace("❯\u{a0}", "❯ existing draft"), 2, 1, false)
                .editor_ready("claude")
        );
        assert!(!Frame::parse("❯ ", 2, 0, false).editor_ready("claude"));
        assert!(!Frame::parse(raw, 0, 1, false).editor_ready("claude"));
        let menu = format!("{raw}\nChoose\n❯ 1. Allow\n  2. Deny");
        assert!(!Frame::parse(&menu, 2, 1, false).editor_ready("claude"));
    }
    #[test]
    fn pi_vim_mode_border_allows_insert_without_allowing_normal_or_drafts() {
        let raw = "\u{1b}[38;2;184;187;38m────────────────────\n\n────────────\u{1b}[7m\u{1b}[38;2;80;73;69m INSERT\n\u{1b}[0mstatus";
        assert!(Frame::parse(raw, 0, 1, true).editor_ready("pi"));
        for mode in ["NORMAL", "VISUAL", "REPLACE", "INSERT extra text"] {
            assert!(!Frame::parse(&raw.replace("INSERT", mode), 0, 1, true).editor_ready("pi"));
        }
        assert!(!Frame::parse(&raw.replace("\n\n", "\ndraft\n"), 0, 1, true).editor_ready("pi"));
        assert!(!Frame::parse(raw, 0, 1, false).editor_ready("pi"));
        assert!(!Frame::parse(raw, 0, 2, true).editor_ready("pi"));
    }
    #[test]
    fn menu_ids_change_with_the_target_and_selection() {
        let frame = Frame::parse(
            "Choose model\n› 1. Model A\n  2. Model B\nPress Enter to confirm",
            0,
            3,
            false,
        );
        let menu = frame.menu("codex", 100).unwrap();
        assert_eq!(menu.options.len(), 2);
        assert!(menu.options[0].selected);
        assert_ne!(menu.id, frame.menu("codex", 101).unwrap().id);
        let changed = Frame::parse(
            "Choose model\n  1. Model A\n› 2. Model B\nPress Enter to confirm · Esc to cancel",
            0,
            3,
            false,
        )
        .menu("codex", 100)
        .unwrap();
        assert_ne!(menu.id, changed.id);
        assert!(
            Frame::parse("answer\n1. explanation\n2. details\n› ", 2, 3, true)
                .menu("codex", 100)
                .is_none()
        );
    }
    #[test]
    fn pi_select_list_uses_unnumbered_arrows_and_dialog_boundaries() {
        let raw = "────────────────────\n\nOnly showing configured models\n\n> \n\n→ model-a\n  model-b\n  model-c\n\nenter to select · esc to cancel\n────────────────────";
        let menu = Frame::parse(raw, 2, 4, true).menu("pi", 100).unwrap();
        assert_eq!(menu.options.len(), 3);
        assert_eq!(menu.options[1].label, "model-b");
        assert!(menu.options[0].selected);
        assert!(
            Frame::parse("→ example\n  continuation", 0, 2, true)
                .menu("pi", 100)
                .is_none()
        );
        assert!(
            Frame::parse(raw.replace("to select", "example").as_str(), 2, 4, true)
                .menu("pi", 100)
                .is_some()
        );
    }
}
