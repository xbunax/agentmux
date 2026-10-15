//! Structural terminal adapters. No model names, command names or approval phrases
//! participate in detection. Native protocol adapters can emit the same card contract.
use crate::{tmux_ui::Frame, *};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::sync::OnceLock;

#[derive(Clone, Serialize, Debug)]
pub struct Choice {
    pub id: usize,
    pub label: String,
    pub selected: bool,
}
#[derive(Clone, Serialize, Debug)]
pub struct Control {
    pub id: String,
    pub label: String,
    #[serde(skip)]
    pub key: String,
}
#[derive(Clone, Serialize, Debug)]
pub struct Menu {
    pub schema: u32,
    pub adapter: String,
    pub id: String,
    pub title: String,
    pub detail: String,
    pub options: Vec<Choice>,
    pub actions: Vec<Control>,
    pub searchable: bool,
    pub query: String,
    pub visible_only: bool,
}
#[derive(Deserialize)]
struct Profiles {
    schema: u32,
    profiles: Vec<Profile>,
}
#[derive(Deserialize)]
struct Profile {
    id: String,
    providers: Vec<String>,
    markers: Vec<String>,
    numbered: bool,
    #[serde(default)]
    search_prefixes: Vec<String>,
    #[serde(default)]
    commands: Vec<CommandHint>,
}
#[derive(Deserialize)]
struct CommandHint {
    name: String,
    description: String,
}
static PROFILES: OnceLock<Profiles> = OnceLock::new();
fn bundled() -> Profiles {
    serde_json::from_str(include_str!("interaction-profiles.json")).expect("bundled profiles")
}
pub fn initialize() -> std::io::Result<()> {
    let mut defaults = bundled();
    if let Some(path) = std::env::var_os("AGENTMUX_UI_PROFILES") {
        let bytes = std::fs::read(path)?;
        if bytes.len() > 262144 {
            return Err(std::io::Error::other("UI profiles exceed 256 KiB"));
        }
        let mut custom: Profiles = serde_json::from_slice(&bytes)?;
        if custom.schema != 1
            || custom.profiles.len() > 64
            || custom.profiles.iter().any(|p| {
                p.id.is_empty()
                    || p.markers.is_empty()
                    || p.markers.iter().any(|m| m.chars().count() != 1)
            })
        {
            return Err(std::io::Error::other(
                "Invalid UI profile schema or focus markers",
            ));
        }
        custom.profiles.append(&mut defaults.profiles);
        defaults = custom;
    }
    let _ = PROFILES.set(defaults);
    Ok(())
}
fn profiles() -> &'static Profiles {
    PROFILES.get_or_init(bundled)
}
pub fn commands(provider: &str) -> Value {
    let mut commands = Vec::new();
    for profile in &profiles().profiles {
        if profile.providers.iter().any(|p| p == provider) {
            for command in &profile.commands {
                if !commands
                    .iter()
                    .any(|old: &Value| old["name"] == command.name)
                {
                    commands.push(
                        json!({"name":command.name,"description":command.description,"kind":"tui"}),
                    );
                }
            }
        }
    }
    json!(commands)
}
fn indent(text: &str) -> usize {
    text.chars().take_while(|c| c.is_whitespace()).count()
}
fn border(text: &str) -> bool {
    text.chars().filter(|c| "─━═".contains(*c)).count() >= 8
}
fn compact(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}
// Only a bounded keyboard vocabulary is executable. Help labels are never shell input.
fn key(token: &str) -> Option<String> {
    let token = token.split('/').next()?;
    if let Some(letter) = token.to_ascii_lowercase().strip_prefix("ctrl+")
        && letter.len() == 1
        && letter.bytes().all(|c| c.is_ascii_alphabetic())
    {
        return Some(format!("C-{letter}"));
    }
    Some(match token.to_ascii_lowercase().as_str() {
        "enter" | "return" => "Enter".into(),
        "esc" | "escape" => "Escape".into(),
        "space" => "Space".into(),
        "tab" => "Tab".into(),
        "↑" | "up" => "Up".into(),
        "↓" | "down" => "Down".into(),
        "←" | "left" => "Left".into(),
        "→" | "right" => "Right".into(),
        _ if token.len() == 1 && token.bytes().all(|c| c.is_ascii_alphanumeric()) => token.into(),
        _ => return None,
    })
}
fn help_controls(text: &str) -> Vec<Control> {
    compact(text)
        .split(['·', '|'])
        .filter_map(|part| {
            let part = part.trim().strip_prefix("Press ").unwrap_or(part.trim());
            let (token, label) = part.split_once(' ')?;
            let key = key(token)?;
            Some(Control {
                id: format!("key:{key}"),
                label: label.trim().to_string(),
                key,
            })
        })
        .collect()
}
struct Row {
    line: usize,
    number: usize,
    label: String,
    selected: bool,
    indent: usize,
    label_column: usize,
}
fn row(text: &str, line: usize, profile: &Profile) -> Option<Row> {
    let trimmed = text.trim_start();
    let marker = profile
        .markers
        .iter()
        .find(|marker| trimmed.starts_with(marker.as_str()));
    let selected = marker.is_some();
    let rest = marker.map_or(trimmed, |m| trimmed[m.len()..].trim_start());
    let (number, label) = if profile.numbered {
        let end = rest.find(['.', ')'])?;
        let number = rest[..end].parse::<usize>().ok()?;
        if number == 0 || number > 999 || !rest[end + 1..].starts_with(char::is_whitespace) {
            return None;
        }
        (number, rest[end + 1..].trim())
    } else {
        if !selected && indent(text) < 2 {
            return None;
        }
        if rest.starts_with(['(', '─', '━', '═', '>']) {
            return None;
        }
        (0, rest.trim())
    };
    if label.is_empty() {
        return None;
    }
    Some(Row {
        line,
        number,
        label: label.into(),
        selected,
        indent: indent(text),
        label_column: text.chars().count() - rest.chars().count()
            + if rest.starts_with("✓ ") { 2 } else { 0 },
    })
}
pub fn detect(frame: &Frame, provider: &str, pid: u32) -> Option<Menu> {
    profiles()
        .profiles
        .iter()
        .filter(|p| p.providers.iter().any(|s| s == provider))
        .find_map(|profile| detect_with(frame, provider, pid, profile))
}
pub fn blocks_editor(frame: &Frame, provider: &str) -> bool {
    if detect(frame, provider, 0).is_some() {
        return true;
    }
    profiles()
        .profiles
        .iter()
        .filter(|p| p.providers.iter().any(|s| s == provider))
        .any(|profile| {
            frame.lines.iter().enumerate().any(|(i, l)| {
                row(&l.text, i, profile).is_some_and(|r| r.selected && i > frame.cursor_y)
            })
        })
}
fn detect_with(frame: &Frame, provider: &str, pid: u32, profile: &Profile) -> Option<Menu> {
    let lines = &frame.lines;
    if profile.numbered
        && frame.cursor_visible
        && lines.get(frame.cursor_y).is_some_and(|line| {
            profile
                .markers
                .iter()
                .any(|m| line.text.trim_start().starts_with(m))
                && row(&line.text, frame.cursor_y, profile).is_none()
        })
    {
        return None;
    }
    let rows: Vec<_> = lines
        .iter()
        .enumerate()
        .filter(|(_, line)| {
            profile.numbered
                || !line
                    .text
                    .chars()
                    .enumerate()
                    .filter(|(_, c)| !c.is_whitespace())
                    .all(|(i, _)| line.dim.get(i) == Some(&true))
        })
        .filter_map(|(i, l)| row(&l.text, i, profile))
        .collect();
    for focused in rows.iter().filter(|r| r.selected).rev() {
        let rows: Vec<_> = rows
            .iter()
            .filter(|r| profile.numbered || r.selected || r.indent == focused.label_column)
            .collect();
        // A numbered editor draft is not a focused dialog.
        if frame.cursor_visible && frame.cursor_y == focused.line {
            continue;
        }
        let pos = rows.iter().position(|r| r.line == focused.line)?;
        let connected = |a: &Row, b: &Row| {
            (!profile.numbered || b.number == a.number + 1)
                && lines[a.line + 1..b.line]
                    .iter()
                    .all(|l| l.text.trim().is_empty() || indent(&l.text) > a.indent.max(b.indent))
        };
        let mut start = pos;
        while start > 0 && connected(rows[start - 1], rows[start]) {
            start -= 1;
        }
        let mut end = pos + 1;
        while end < rows.len() && connected(rows[end - 1], rows[end]) {
            end += 1;
        }
        if end - start > 80 || rows[start..end].iter().filter(|r| r.selected).count() != 1 {
            continue;
        }
        let first = rows[start].line;
        let last = rows[end - 1].line;
        let tail = &lines[last + 1..];
        let help_start = tail
            .iter()
            .position(|l| {
                l.text
                    .trim()
                    .strip_prefix("Press ")
                    .unwrap_or(l.text.trim())
                    .split_whitespace()
                    .next()
                    .is_some_and(|t| t.len() > 1 && key(t).is_some())
            })
            .unwrap_or(tail.len());
        let footer = tail[help_start..]
            .iter()
            .map(|l| l.text.as_str())
            .collect::<Vec<_>>()
            .join(" ");
        let mut actions = help_controls(&footer);
        let has_help = actions.iter().any(|a| a.key == "Enter");
        let search = lines[..first].iter().enumerate().rev().find_map(|(i, l)| {
            profile.search_prefixes.iter().find_map(|prefix| {
                let t = l.text.trim_start();
                t.strip_prefix(prefix.as_str())
                    .filter(|rest| rest.is_empty() || rest.starts_with(char::is_whitespace))
                    .map(|rest| (i, rest.trim().to_string()))
            })
        });
        // Search field + enclosing top border is sufficient even when a short pane
        // clips the bottom help. Plain arrows in conversation text are not controls.
        let container = search
            .as_ref()
            .is_some_and(|(i, _)| lines[..*i].iter().any(|l| border(&l.text)));
        if !has_help && !(container && !profile.numbered) {
            continue;
        }
        if !profile.numbered && !container && !lines[..first].iter().any(|l| border(&l.text)) {
            continue;
        }
        if !has_help {
            actions.extend([
                Control {
                    id: "key:Enter".into(),
                    label: "确认选择".into(),
                    key: "Enter".into(),
                },
                Control {
                    id: "key:Escape".into(),
                    label: "取消".into(),
                    key: "Escape".into(),
                },
            ]);
        }
        if tail.iter().any(|l| l.text.contains("←/→")) {
            actions.extend([
                Control {
                    id: "key:Left".into(),
                    label: "向左调整".into(),
                    key: "Left".into(),
                },
                Control {
                    id: "key:Right".into(),
                    label: "向右调整".into(),
                    key: "Right".into(),
                },
            ]);
        }
        // Labels describe navigation, independent of menu purpose or provider.
        actions.extend([
            Control {
                id: "previous".into(),
                label: "上一项".into(),
                key: "Up".into(),
            },
            Control {
                id: "next".into(),
                label: "下一项".into(),
                key: "Down".into(),
            },
        ]);
        let mut options = Vec::new();
        for (i, r) in rows[start..end].iter().enumerate() {
            let stop = rows[start..end].get(i + 1).map_or(lines.len(), |n| n.line);
            let continuation = lines[r.line + 1..stop]
                .iter()
                .take_while(|l| {
                    !l.text.trim().is_empty()
                        && indent(&l.text)
                            > if profile.numbered {
                                r.indent
                            } else {
                                focused.label_column
                            }
                        && !border(&l.text)
                })
                .map(|l| l.text.trim())
                .collect::<Vec<_>>()
                .join(" ");
            options.push(Choice {
                id: i,
                label: compact(&format!("{} {}", r.label, continuation)),
                selected: r.selected,
            });
        }
        let top = lines[..first]
            .iter()
            .rposition(|l| border(&l.text))
            .map_or(first.saturating_sub(8), |n| n + 1);
        let context = lines[top..first]
            .iter()
            .filter(|l| !l.text.trim().is_empty())
            .map(|l| l.text.trim())
            .collect::<Vec<_>>();
        let title = lines[top..first]
            .iter()
            .rev()
            .find(|l| {
                !l.text.trim().is_empty()
                    && indent(&l.text) <= focused.indent
                    && !l.text.trim().starts_with('>')
            })
            .map_or("Agent 等待你的选择".into(), |l| {
                l.text.trim().to_string()
            });
        let detail = context.join("\n");
        let searchable = search.as_ref().is_some_and(|(i, _)| {
            frame.cursor_y == *i
                && (frame.cursor_visible
                    || lines[*i]
                        .inverse
                        .get(frame.cursor_x)
                        .copied()
                        .unwrap_or(false))
        });
        let query = search.map_or(String::new(), |(_, q)| q);
        let id = format!(
            "{:x}",
            Sha256::digest(format!(
                "{provider}:{pid}:{}:{detail}:{options:?}:{actions:?}:{query}:{searchable}",
                profile.id
            ))
        );
        return Some(Menu {
            schema: 1,
            adapter: profile.id.clone(),
            id,
            title,
            detail,
            options,
            actions,
            searchable,
            query,
            visible_only: true,
        });
    }
    None
}

pub fn executable(menu: &Menu, id: &str) -> Result<String> {
    menu.actions
        .iter()
        .find(|c| c.id == id)
        .map(|c| c.key.clone())
        .ok_or_else(|| bad("操作不在当前交互卡片中"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[derive(Deserialize)]
    struct Fixture {
        provider: String,
        raw: String,
        cursor_x: usize,
        cursor_y: usize,
        cursor_visible: bool,
    }
    #[test]
    fn actual_narrow_reasoning_claude_and_pi_menus_are_not_special_cased_by_title() {
        for source in [
            include_str!("../tests/fixtures/interactions/codex-narrow.json"),
            include_str!("../tests/fixtures/interactions/claude-narrow.json"),
            include_str!("../tests/fixtures/interactions/pi-narrow.json"),
        ] {
            let f: Fixture = serde_json::from_str(source).unwrap();
            let frame = Frame::parse(&f.raw, f.cursor_x, f.cursor_y, f.cursor_visible);
            let card = detect(&frame, &f.provider, 12)
                .unwrap_or_else(|| panic!("Missing {} menu", f.provider));
            assert!(card.options.len() >= 3);
            assert_eq!(card.options.iter().filter(|o| o.selected).count(), 1);
            assert!(!frame.editor_ready(&f.provider));
            assert!(executable(&card, "next").is_ok());
            assert!(executable(&card, "arbitrary-shell-command").is_err());
        }
    }
    #[test]
    fn printed_examples_above_the_active_editor_are_not_controls() {
        let frame = Frame::parse(
            "Example\n› 1. printed answer\n  2. printed alternative\nEnter to choose · Esc to cancel\n\n› ",
            2,
            5,
            true,
        );
        assert!(detect(&frame, "codex", 12).is_none());
        assert!(frame.editor_ready("codex"));
    }
    #[test]
    fn single_search_result_does_not_include_dim_annotations_as_options() {
        let frame = Frame::parse(
            "────────────────────\n> query\n\n→   result\n\n\u{1b}[2m  arbitrary annotation\n  continuation\u{1b}[0m\n\nEnter to select · Ctrl+S to save · Escape/Ctrl+C to cancel\n────────────────────",
            7,
            1,
            true,
        );
        let card = detect(&frame, "pi", 12).unwrap();
        assert_eq!(card.options.len(), 1);
        assert_eq!(card.options[0].label, "result");
        assert_eq!(executable(&card, "key:C-s").unwrap(), "C-s");
        assert_eq!(executable(&card, "key:Escape").unwrap(), "Escape");
    }
    #[test]
    fn data_profiles_support_unseen_prompts_and_style_without_a_scenario_branch() {
        let profile: Profile = serde_json::from_str(
            r#"{"id":"other-theme","providers":["example"],"markers":["▸"],"numbered":true}"#,
        )
        .unwrap();
        let frame = Frame::parse(
            "Choose a delivery region\n▸ 1. lunar-base\n       long wrapped description\n  2. submarine\n       another description\nEnter to choose · Esc to return",
            0,
            6,
            false,
        );
        let card = detect_with(&frame, "example", 12, &profile).unwrap();
        assert!(card.options[0].label.contains("long wrapped description"));
        assert_eq!(card.options[1].label, "submarine another description");
    }
}
