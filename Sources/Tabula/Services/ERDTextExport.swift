import Foundation

// STUB — replaced by the text exporter implementation.
/// Text-based ER diagram exports. All functions are pure (graph in, text out).
enum ERDTextExport {
    /// Mermaid `erDiagram` (renders in GitHub, GitLab, Notion, Obsidian, Confluence).
    static func mermaid(_ g: ERDGraph) -> String { "erDiagram\n" }
    /// DBML for dbdiagram.io / dbdocs.
    static func dbml(_ g: ERDGraph) -> String { "" }
    /// PlantUML entity-relationship (IE notation).
    static func plantUML(_ g: ERDGraph) -> String { "@startuml\n@enduml\n" }
    /// Graphviz DOT with HTML-like table labels.
    static func dot(_ g: ERDGraph) -> String { "digraph ERD {}\n" }
    /// Markdown data dictionary (one section per table + relationship list).
    static func markdownDictionary(_ g: ERDGraph) -> String { "# \(g.title)\n" }
}
