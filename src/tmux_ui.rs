//! Read standard Agent editors and menus without treating terminal output as chat history.
use crate::*;
use sha2::{Digest, Sha256};
#[derive(Clone, Default, Debug)]
struct Line {
    text: String,
    dim: Vec<bool>,
    inverse: Vec<bool>,
}
fn line(raw: &str) -> Line {
    let mut parsed = Line::default();
    let mut dim = false;
    let mut inverse = false;
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
    parsed
}
#[derive(Clone)]
pub struct Frame {
    lines: Vec<Line>,
    pub cursor_x: usize,
    pub cursor_y: usize,
    cursor_visible: bool,
}
#[derive(Clone, Serialize, Debug)]
pub struct Choice {
    pub id: usize,
    pub label: String,
    pub selected: bool,
}
#[derive(Clone, Serialize, Debug)]
pub struct Menu {
    pub id: String,
    pub title: String,
    pub detail: String,
    pub options: Vec<Choice>,
}
impl Frame {
    pub fn parse(raw: &str, cursor_x: usize, cursor_y: usize, cursor_visible: bool) -> Self {
        Self {
            lines: raw.lines().map(line).collect(),
            cursor_x,
            cursor_y,
            cursor_visible,
        }
    }
    pub fn editor_ready(&self, provider: &str) -> bool {
        let Some(line) = self.lines.get(self.cursor_y) else {
            return false;
        };
        let trimmed = line.text.trim_start();
        if provider == "pi" {
            let border = |line: &Line| {
                let s = line.text.trim();
                s.starts_with('─')
                    && s.ends_with('─')
                    && s.chars().filter(|c| *c == '─').count() >= 8
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
                && self.lines.get(self.cursor_y + 1).is_some_and(border);
        }
        let prompt = match provider {
            "codex" => '›',
            "claude" => '❯',
            _ => return false,
        };
        if !self.cursor_visible || !trimmed.starts_with(prompt) {
            return false;
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
        if provider == "pi" {
            return self.pi_menu(pid);
        }
        let marker = |s: &str| s.starts_with(['›', '❯', '>', '→']);
        let option = |s: &str| -> Option<(usize, String)> {
            let s = s.trim_start();
            let s = if marker(s) {
                s.chars().skip(1).collect::<String>()
            } else {
                s.into()
            };
            let s = s.trim_start();
            let end = s.find(['.', ')'])?;
            let number = s[..end].parse::<usize>().ok()?;
            if number == 0 || number > 99 || !s[end + 1..].starts_with(char::is_whitespace) {
                return None;
            }
            Some((number, s[end + 1..].trim().to_owned()))
        };
        for (selected, line) in self.lines.iter().enumerate().rev() {
            if !marker(line.text.trim_start()) || option(&line.text).is_none() {
                continue;
            }
            let mut start = selected;
            while start > 0 && option(&self.lines[start - 1].text).is_some() {
                start -= 1;
            }
            let mut end = selected + 1;
            while end < self.lines.len() && option(&self.lines[end].text).is_some() {
                end += 1;
            }
            if end - start < 2
                || end - start > 20
                || (self.cursor_visible && end == selected + 1 && self.cursor_y == selected)
            {
                continue;
            }
            let options: Vec<_> = self.lines[start..end]
                .iter()
                .enumerate()
                .map(|(index, line)| Choice {
                    id: index,
                    label: option(&line.text).unwrap().1,
                    selected: start + index == selected,
                })
                .collect();
            let context: Vec<_> = self.lines[start.saturating_sub(8)..start]
                .iter()
                .map(|l| l.text.trim())
                .filter(|s| !s.is_empty() && !s.chars().all(|c| "─━═│┌┐└┘╭╮╰╯ ".contains(c)))
                .collect();
            let title = context
                .last()
                .copied()
                .unwrap_or("Agent 等待你的选择")
                .to_string();
            let detail = context.join("\n");
            let id = format!(
                "{:x}",
                Sha256::digest(format!("{provider}:{pid}:{detail}:{options:?}"))
            );
            return Some(Menu {
                id,
                title,
                detail,
                options,
            });
        }
        None
    }
    fn pi_menu(&self, pid: u32) -> Option<Menu> {
        // Pi's SelectList uses an unnumbered arrow, with the cursor in a separate
        // search field. Require its dialog border and explicit keyboard help;
        // an arrow in ordinary conversation output must never become a control.
        let option = |line: &Line| -> Option<String> {
            let text = line.text.as_str();
            let label = text
                .strip_prefix("→ ")
                .or_else(|| text.strip_prefix("  "))?;
            let label = label.trim();
            if label.is_empty() || label.starts_with('(') || label.starts_with('─') {
                return None;
            }
            Some(label.to_string())
        };
        for (selected, line) in self.lines.iter().enumerate().rev() {
            if !line.text.starts_with("→ ") {
                continue;
            }
            let mut start = selected;
            while start > 0 && option(&self.lines[start - 1]).is_some() {
                start -= 1;
            }
            let mut end = selected + 1;
            while end < self.lines.len() && option(&self.lines[end]).is_some() {
                end += 1;
            }
            if end - start > 30
                || self.lines[start..end]
                    .iter()
                    .filter(|l| l.text.starts_with("→ "))
                    .count()
                    != 1
            {
                continue;
            }
            let border = |l: &Line| l.text.trim().chars().filter(|c| *c == '─').count() >= 8;
            let Some(top) = self.lines[..start].iter().rposition(border) else {
                continue;
            };
            let Some(bottom) = self.lines[end..].iter().position(border) else {
                continue;
            };
            let footer = self.lines[end..end + bottom]
                .iter()
                .map(|l| l.text.to_lowercase())
                .collect::<Vec<_>>()
                .join(" ");
            if !footer.contains("to select") || !footer.contains("to cancel") {
                continue;
            }
            let detail = self.lines[top + 1..start]
                .iter()
                .map(|l| l.text.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            let options: Vec<_> = self.lines[start..end]
                .iter()
                .enumerate()
                .map(|(index, line)| Choice {
                    id: index,
                    label: option(line).unwrap(),
                    selected: start + index == selected,
                })
                .collect();
            let id = format!(
                "{:x}",
                Sha256::digest(format!("pi:{pid}:{detail}:{options:?}"))
            );
            return Some(Menu {
                id,
                title: "Pi · 选择选项".into(),
                detail,
                options,
            });
        }
        None
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
    let values: &[(&str, &str)] = match provider {
        "codex" => &[
            ("model", "在当前 Codex 中选择模型"),
            ("compact", "压缩当前会话"),
            ("status", "查看 Codex 状态"),
            ("permissions", "查看或调整 Codex 权限"),
        ],
        "claude" => &[
            ("model", "在当前 Claude Code 中选择模型"),
            ("compact", "压缩当前会话"),
            ("permissions", "查看或调整权限"),
            ("status", "查看 Claude Code 状态"),
            ("help", "查看命令帮助"),
        ],
        "pi" => &[
            ("model", "在当前 Pi 中选择模型"),
            ("compact", "压缩当前会话"),
            ("settings", "打开 Pi 设置"),
            ("session", "查看会话信息"),
            ("resume", "选择已有 Pi 会话"),
        ],
        _ => &[],
    };
    serde_json::json!(values.iter().map(|(name,description)|serde_json::json!({"name":name,"description":description,"kind":"tui"})).collect::<Vec<_>>())
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
            "Choose model\n  1. Model A\n› 2. Model B\nPress Enter to confirm",
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
                .is_none()
        );
    }
}
