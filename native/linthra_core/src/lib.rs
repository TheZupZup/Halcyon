//! High-performance, dependency-free library primitives for Linthra.
//!
//! The first responsibility of this crate is intentionally narrow: index and
//! search very large music libraries without asking Flutter to walk hundreds of
//! thousands of Dart objects for every query. The public API is platform-neutral
//! so Android/iOS/desktop bindings can be added later without changing the core.

use std::collections::{BTreeMap, HashMap, HashSet};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrackRecord {
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    pub album_artist: Option<String>,
    pub provider: String,
}

impl TrackRecord {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        artist: impl Into<String>,
        album: impl Into<String>,
        album_artist: Option<String>,
        provider: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            artist: artist.into(),
            album: album.into(),
            album_artist,
            provider: provider.into(),
        }
    }
}

#[derive(Clone, Copy, Debug)]
struct Posting {
    track_index: usize,
    weight: u16,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SearchHit<'a> {
    pub track: &'a TrackRecord,
    pub score: u32,
}

/// Immutable inverted index designed for fast repeated searches.
///
/// Tokens live in a BTreeMap rather than a HashMap because the ordered keyspace
/// makes prefix lookup (`metal` → `metallica`) logarithmic to enter and linear
/// only in the number of matching tokens. Query work therefore scales with the
/// relevant postings, not the full catalog size.
pub struct LibraryIndex {
    tracks: Vec<TrackRecord>,
    postings: BTreeMap<String, Vec<Posting>>,
}

impl LibraryIndex {
    pub fn build(tracks: Vec<TrackRecord>) -> Self {
        let mut postings: BTreeMap<String, Vec<Posting>> = BTreeMap::new();

        for (track_index, track) in tracks.iter().enumerate() {
            index_field(&mut postings, track_index, &track.title, 12);
            index_field(&mut postings, track_index, &track.artist, 8);
            index_field(&mut postings, track_index, &track.album, 5);
            if let Some(album_artist) = &track.album_artist {
                index_field(&mut postings, track_index, album_artist, 6);
            }
            // Provider is intentionally searchable at a low weight. It makes
            // diagnostics/power-user searches useful without outranking music
            // metadata (e.g. "navidrome halo").
            index_field(&mut postings, track_index, &track.provider, 2);
        }

        Self { tracks, postings }
    }

    pub fn len(&self) -> usize {
        self.tracks.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tracks.is_empty()
    }

    /// Searches using AND semantics across query terms and prefix semantics
    /// within each term. Results are ranked by field importance and exact-token
    /// matches, then deterministically by title/id for stable UI ordering.
    pub fn search(&self, query: &str, limit: usize) -> Vec<SearchHit<'_>> {
        if limit == 0 || self.tracks.is_empty() {
            return Vec::new();
        }

        let terms = normalized_tokens(query);
        if terms.is_empty() {
            return Vec::new();
        }

        let mut candidates: Option<HashMap<usize, u32>> = None;

        for term in terms {
            let mut best_for_term: HashMap<usize, u16> = HashMap::new();

            for (token, token_postings) in self.postings.range(term.clone()..) {
                if !token.starts_with(&term) {
                    break;
                }
                let exact_bonus: u16 = if token == &term { 3 } else { 0 };
                for posting in token_postings {
                    let score = posting.weight.saturating_add(exact_bonus);
                    best_for_term
                        .entry(posting.track_index)
                        .and_modify(|best| *best = (*best).max(score))
                        .or_insert(score);
                }
            }

            if best_for_term.is_empty() {
                return Vec::new();
            }

            candidates = Some(match candidates {
                None => best_for_term
                    .into_iter()
                    .map(|(index, score)| (index, u32::from(score)))
                    .collect(),
                Some(mut current) => {
                    current.retain(|index, total| {
                        if let Some(score) = best_for_term.get(index) {
                            *total += u32::from(*score);
                            true
                        } else {
                            false
                        }
                    });
                    if current.is_empty() {
                        return Vec::new();
                    }
                    current
                }
            });
        }

        let mut ranked: Vec<(usize, u32)> = candidates.unwrap_or_default().into_iter().collect();
        ranked.sort_unstable_by(|(left_index, left_score), (right_index, right_score)| {
            right_score
                .cmp(left_score)
                .then_with(|| {
                    self.tracks[*left_index]
                        .title
                        .cmp(&self.tracks[*right_index].title)
                })
                .then_with(|| self.tracks[*left_index].id.cmp(&self.tracks[*right_index].id))
        });
        ranked.truncate(limit);

        ranked
            .into_iter()
            .map(|(track_index, score)| SearchHit {
                track: &self.tracks[track_index],
                score,
            })
            .collect()
    }
}

fn index_field(
    postings: &mut BTreeMap<String, Vec<Posting>>,
    track_index: usize,
    value: &str,
    weight: u16,
) {
    // Deduplicate within one field so "Very Very Good" does not artificially
    // outrank another track merely because a token is repeated in its metadata.
    let unique: HashSet<String> = normalized_tokens(value).into_iter().collect();
    for token in unique {
        postings
            .entry(token)
            .or_default()
            .push(Posting { track_index, weight });
    }
}

fn normalized_tokens(value: &str) -> Vec<String> {
    value
        .split(|character: char| !character.is_alphanumeric())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_lowercase())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{LibraryIndex, TrackRecord};

    fn fixture() -> LibraryIndex {
        LibraryIndex::build(vec![
            TrackRecord::new(
                "1",
                "Master of Puppets",
                "Metallica",
                "Master of Puppets",
                Some("Metallica".into()),
                "navidrome",
            ),
            TrackRecord::new(
                "2",
                "Battery",
                "Metallica",
                "Master of Puppets",
                Some("Metallica".into()),
                "jellyfin",
            ),
            TrackRecord::new(
                "3",
                "Master Blaster",
                "Stevie Wonder",
                "Hotter than July",
                None,
                "local",
            ),
        ])
    }

    #[test]
    fn exact_multi_term_search_prefers_title_and_artist() {
        let index = fixture();
        let hits = index.search("metallica master", 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].track.id, "1");
    }

    #[test]
    fn prefix_search_does_not_scan_for_an_exact_full_word() {
        let index = fixture();
        let hits = index.search("met mast", 10);
        assert_eq!(hits.len(), 2);
        assert_eq!(hits[0].track.id, "1");
    }

    #[test]
    fn query_terms_have_and_semantics() {
        let index = fixture();
        let hits = index.search("stevie puppets", 10);
        assert!(hits.is_empty());
    }

    #[test]
    fn provider_can_be_used_as_a_low_weight_filter_term() {
        let index = fixture();
        let hits = index.search("jellyfin battery", 10);
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].track.id, "2");
    }
}
