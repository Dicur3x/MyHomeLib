use std::sync::Arc;

use docboss_font::{bounds as path_bounds, FontDatabase};
use docboss_layout::{Item, Rect};
use docboss_model::{
    Block, Document, Drawing, DrawingPlacement, DrawingPosition, FontEntry, Inline, Media, MediaId,
    PageMargins, Paragraph, PositionBase, Run, RunContent, Section, Severity, Styles,
};

const EMU_PER_POINT: f32 = 12_700.0;
const EMU_PER_TWIP: i64 = 635;
const PADDING: f32 = 4.0;
const MAX_PIXELS: f32 = 16.0 * 1024.0 * 1024.0;
const MAX_SIDE: f32 = 8192.0;
const MAX_IMAGE_BYTES: usize = 16 * 1024 * 1024;

#[derive(Default)]
pub struct DrawingCounts {
    pub rasterized: usize,
    pub incomplete: usize,
    pub dropped: usize,
}

pub fn preserve_groups(doc: &mut Document, byte_budget: usize) -> DrawingCounts {
    let mut painter = GroupPainter {
        styles: &doc.styles,
        fonts: &doc.fonts,
        font_database: None,
        media: &mut doc.media,
        byte_budget,
        counts: DrawingCounts::default(),
    };
    for section in &mut doc.sections {
        painter.blocks(&mut section.blocks);
    }
    for part in &mut doc.headers_footers {
        painter.blocks(&mut part.blocks);
    }
    for note in doc.footnotes.iter_mut().chain(&mut doc.endnotes) {
        painter.blocks(&mut note.blocks);
    }
    for comment in &mut doc.comments {
        painter.blocks(&mut comment.blocks);
    }
    painter.counts
}

struct GroupPainter<'a> {
    styles: &'a Styles,
    fonts: &'a [FontEntry],
    font_database: Option<Arc<FontDatabase>>,
    media: &'a mut Vec<Media>,
    byte_budget: usize,
    counts: DrawingCounts,
}

struct RasterizedGroup {
    data: Vec<u8>,
    bounds: [f32; 4],
    incomplete: bool,
}

impl GroupPainter<'_> {
    fn blocks(&mut self, blocks: &mut [Block]) {
        for block in blocks {
            match block {
                Block::Paragraph(paragraph) => self.inlines(&mut paragraph.inlines),
                Block::Table(table) => {
                    for cell in table.rows.iter_mut().flat_map(|row| &mut row.cells) {
                        self.blocks(&mut cell.blocks);
                    }
                }
            }
        }
    }

    fn inlines(&mut self, inlines: &mut [Inline]) {
        for inline in inlines {
            match inline {
                Inline::Run(run) => {
                    for content in &mut run.content {
                        if let RunContent::Drawing(drawing) = content {
                            if !drawing.members.is_empty() && drawing.media.is_none() {
                                self.group(drawing);
                            }
                        }
                    }
                }
                Inline::Field(field) => self.inlines(&mut field.result),
                Inline::Hyperlink(link) => self.inlines(&mut link.inlines),
                Inline::Revision(revision) => self.inlines(&mut revision.inlines),
                _ => {}
            }
        }
    }

    fn group(&mut self, drawing: &mut Drawing) {
        let Some(RasterizedGroup { data, bounds, incomplete }) = self.render(drawing) else {
            self.counts.dropped += 1;
            return;
        };
        self.byte_budget -= data.len();
        let id = self.media.len();
        self.media.push(Media {
            name: format!("media/homelibre-shape-{}.png", id + 1),
            content_type: "image/png".into(),
            data: data.into(),
        });
        drawing.media = Some(MediaId(id as u32));
        if drawing.description.as_deref().is_none_or(str::is_empty) {
            let labels: Vec<_> = drawing.members.iter()
                .flat_map(|member| &member.drawing.text_box)
                .filter_map(|block| match block {
                    Block::Paragraph(paragraph) => Some(paragraph.text()),
                    Block::Table(_) => None,
                })
                .filter(|label| !label.trim().is_empty())
                .collect();
            if !labels.is_empty() {
                drawing.description = Some(labels.join(" ").chars().take(4096).collect());
            }
        }
        if let DrawingPlacement::Anchored { horizontal, vertical, .. } = &mut drawing.placement {
            // Retain where the source group starts if the frame grows to
            // contain a line, arrowhead or an indirect child outside it.
            horizontal.offset = horizontal.offset.saturating_add(to_emu(bounds[0] - PADDING));
            vertical.offset = vertical.offset.saturating_add(to_emu(bounds[1] - PADDING));
        }
        drawing.width = to_emu(bounds[2] - bounds[0]);
        drawing.height = to_emu(bounds[3] - bounds[1]);
        drawing.members.clear();
        self.counts.rasterized += 1;
        self.counts.incomplete += usize::from(incomplete);
    }

    fn render(&mut self, original: &Drawing) -> Option<RasterizedGroup> {
        if self.byte_budget == 0 || original.width <= 0 || original.height <= 0 {
            return None;
        }
        let mut drawing = original.clone();
        drawing.placement = DrawingPlacement::Anchored {
            horizontal: DrawingPosition::offset(PositionBase::Page, to_emu(PADDING)),
            vertical: DrawingPosition::offset(PositionBase::Page, to_emu(PADDING)),
            behind_text: false,
        };
        drawing.wrap = Default::default();
        let mut section = Section::default();
        section.properties.margins = PageMargins {
            top: 0, right: 0, bottom: 0, left: 0, header: 0, footer: 0, gutter: 0,
        };
        section.properties.page_size.width = frame_twips(drawing.width)?;
        section.properties.page_size.height = frame_twips(drawing.height)?;
        section.blocks.push(Block::Paragraph(Paragraph {
            inlines: vec![Inline::Run(Run {
                content: vec![RunContent::Drawing(Box::new(drawing))],
                ..Default::default()
            })],
            ..Default::default()
        }));
        let part = Document {
            styles: self.styles.clone(),
            media: self.media.clone(),
            fonts: self.fonts.to_vec(),
            sections: vec![section],
            ..Default::default()
        };
        let fonts = self.font_database.get_or_insert_with(|| docboss_layout::fonts_for(&part));
        let mut layout = docboss_layout::layout(&part, fonts);
        let layout_lost_content = layout.diagnostics.iter().any(|diagnostic| diagnostic.severity == Severity::Dropped);
        let [page] = layout.pages.as_mut_slice() else { return None; };
        let mut bounds = [0.0, 0.0, page.width, page.height];
        for item in &page.items {
            if let Some((rect, margin)) = item_bounds(item) {
                bounds[0] = bounds[0].min(rect[0] - PADDING - margin);
                bounds[1] = bounds[1].min(rect[1] - PADDING - margin);
                bounds[2] = bounds[2].max(rect[2] + PADDING + margin);
                bounds[3] = bounds[3].max(rect[3] + PADDING + margin);
            }
        }
        page.width = bounds[2] - bounds[0];
        page.height = bounds[3] - bounds[1];
        let scale = 2.5_f32.min(MAX_SIDE / page.width.max(page.height))
            .min((MAX_PIXELS / (page.width * page.height)).sqrt());
        if !scale.is_finite() || scale <= 0.0 {
            return None;
        }
        if bounds[0] < 0.0 || bounds[1] < 0.0 {
            page.items.insert(0, Item::TransformBegin([1.0, 0.0, 0.0, 1.0, -bounds[0], -bounds[1]]));
            page.items.push(Item::TransformEnd);
        }
        let image = docboss_render::render_page(&layout, 0, scale).ok()?;
        if !image.data.chunks_exact(4).any(|rgba| rgba[..3] != [255; 3]) {
            return None;
        }
        let data = image.encode(docboss_render::Format::Png).ok()?;
        (data.len() <= self.byte_budget.min(MAX_IMAGE_BYTES)).then_some(RasterizedGroup {
            data, bounds, incomplete: layout_lost_content || !image.diagnostics.is_empty(),
        })
    }
}

fn item_bounds(item: &Item) -> Option<([f32; 4], f32)> {
    let box_edges = |box_: &Rect| [box_.x, box_.y, box_.right(), box_.bottom()];
    Some(match item {
        Item::Path { segs, stroke, .. } => (path_bounds(segs)?, stroke.as_ref().map_or(0.0, |s| s.width)),
        Item::Shade { segs, .. } | Item::Picture { segs, .. } => (path_bounds(segs)?, 0.0),
        Item::Outline { rect, width, .. } => (box_edges(rect), *width),
        Item::Rect { rect, .. } | Item::Image { rect, .. } => (box_edges(rect), 0.0),
        Item::Line { from, to, width, .. } => (
            [from.0.min(to.0), from.1.min(to.1), from.0.max(to.0), from.1.max(to.1)], *width,
        ),
        _ => return None,
    })
}

fn to_emu(points: f32) -> i64 {
    (points * EMU_PER_POINT).round() as i64
}

fn frame_twips(emu: i64) -> Option<i32> {
    let padded = emu.checked_add(2 * to_emu(PADDING) + EMU_PER_TWIP - 1)?;
    i32::try_from(padded / EMU_PER_TWIP).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use docboss_model::{Color, Geometry, GroupMember, ShapeFormat};

    #[test]
    fn keeps_visible_parts_when_a_group_contains_a_broken_image() {
        let rectangle = Drawing {
            width: 500_000, height: 350_000,
            geometry: Some(Box::new(Geometry::rectangle())),
            shape: ShapeFormat { fill: Some(Color::BLACK), ..Default::default() },
            ..Default::default()
        };
        let broken_picture = Drawing {
            media: Some(MediaId(0)), width: 400_000, height: 300_000, ..Default::default()
        };
        let group = Drawing {
            width: 950_000, height: 350_000,
            members: vec![
                GroupMember { x: 0, y: 0, drawing: rectangle },
                GroupMember { x: 550_000, y: 0, drawing: broken_picture },
            ],
            ..Default::default()
        };
        let mut document = Document::default();
        document.media.push(Media {
            name: "broken.png".into(), content_type: "image/png".into(), data: b"invalid PNG".as_slice().into(),
        });
        document.sections.push(Section {
            blocks: vec![Block::Paragraph(Paragraph {
                inlines: vec![Inline::Run(Run {
                    content: vec![RunContent::Drawing(Box::new(group))], ..Default::default()
                })],
                ..Default::default()
            })],
            ..Default::default()
        });
        let counts = preserve_groups(&mut document, MAX_IMAGE_BYTES);
        assert_eq!((counts.rasterized, counts.incomplete, counts.dropped), (1, 1, 0));
        assert!(document.media[1].data.starts_with(b"\x89PNG\r\n\x1a\n"));
    }
}
