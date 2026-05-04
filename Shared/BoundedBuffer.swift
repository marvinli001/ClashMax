import Foundation

struct BoundedBuffer<Element> {
  private(set) var elements: [Element] = []
  let limit: Int

  init(limit: Int) {
    self.limit = limit
  }

  mutating func append(_ element: Element) {
    elements.append(element)
    trim()
  }

  mutating func replace(with newElements: [Element]) {
    elements = Array(newElements.suffix(limit))
  }

  private mutating func trim() {
    if elements.count > limit {
      elements.removeFirst(elements.count - limit)
    }
  }
}

