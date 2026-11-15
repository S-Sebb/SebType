// SebType core: paging for engines that hand the core their whole candidate list. MIT, SebType.
#include <sebtype/engine.h>

namespace sebtype {

std::string Preedit::text() const {
  std::string s;
  for (const auto &seg : segments) s += seg.text;
  return s;
}

namespace {
// The page that holds the highlighted candidate (the first page when none is).
int pageStart(Engine &e) {
  const int size = e.pageSize(), h = e.highlighted();
  return size > 0 && h > 0 ? h / size * size : 0;
}
}  // namespace

Page Engine::page() {
  Page page;
  const int size = pageSize(), start = pageStart(*this), h = highlighted();
  if (size <= 0) return page;
  Candidate c;
  for (int i = start; i < start + size && candidateAt(i, c); ++i) {
    if (i == h) page.cursor = i - start;
    page.labels.push_back(label(i - start));
    page.items.push_back(std::move(c));
  }
  page.hasPrev = start > 0;
  page.hasNext = candidateAt(start + size, c);
  return page;
}

std::vector<Candidate> Engine::candidates(int max) {
  std::vector<Candidate> list;
  Candidate c;
  for (int i = 0; i < max && candidateAt(i, c); ++i) list.push_back(std::move(c));
  return list;
}

void Engine::select(int indexOnPage) { selectAt(pageStart(*this) + indexOnPage); }

void Engine::changePage(bool next) {
  const int size = pageSize(), start = pageStart(*this);
  Candidate c;
  if (next && candidateAt(start + size, c)) highlightAt(start + size);
  else if (!next && start > 0) highlightAt(start - size);
}

}  // namespace sebtype
