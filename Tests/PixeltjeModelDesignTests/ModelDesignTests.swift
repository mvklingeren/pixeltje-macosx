import Foundation
import PixeltjeModelDesign
import Testing

@Test func starterRoundTripsAndHasStableArchitectureIdentity() throws {
  let starter = ModelDesignDocument.starter()
  let report = ModelDesignValidator.validate(starter)
  #expect(report.isValid)
  #expect(report.shapes[starter.nodes.last!.id] == [3, 64, 64])
  #expect(try ModelDesignJSON.decode(ModelDesignJSON.encode(starter)) == starter)

  var presentationEdit = starter
  presentationEdit.name = "Renamed"
  presentationEdit.id = UUID()
  presentationEdit.nodes[0].position.x += 100
  presentationEdit.nodes[1].name = "Other label"
  presentationEdit.training.epochs = 20
  presentationEdit.nodes[0].units = 999
  #expect(try ModelDesignJSON.architectureSHA256(presentationEdit)
    == ModelDesignJSON.architectureSHA256(starter))

  presentationEdit.nodes[1].units = 6
  #expect(try ModelDesignJSON.architectureSHA256(presentationEdit)
    != ModelDesignJSON.architectureSHA256(starter))
}

@Test func mergeChecksShapesAndPythonUsesTheSameBranches() throws {
  let input = ModelNode.make(.input, at: .init(x: 0, y: 0))
  var left = ModelNode.make(.layer, at: .init(x: 200, y: 0))
  left.units = 3
  var right = ModelNode.make(.layer, at: .init(x: 200, y: 200))
  right.units = 3
  var merge = ModelNode.make(.merge, at: .init(x: 400, y: 100))
  merge.merge = .add
  let output = ModelNode.make(.output, at: .init(x: 600, y: 100))
  var design = ModelDesignDocument(name: "Branch", nodes: [input, left, right, merge, output],
    edges: [
      .init(source: input.id, target: left.id),
      .init(source: input.id, target: right.id),
      .init(source: left.id, target: merge.id, input: "left"),
      .init(source: right.id, target: merge.id, input: "right"),
      .init(source: merge.id, target: output.id),
    ])
  #expect(ModelDesignValidator.validate(design).isValid)
  let source = try ModelPythonExporter.modelSource(design)
  #expect(source.contains(" + "))
  #expect(source.contains("nn.Conv2d"))

  design.nodes[2].units = 4
  #expect(ModelDesignValidator.validate(design).issues.contains {
    $0.message == "Add requires equal tensor shapes."
  })
}

@Test func graphCannotExportWithoutAParameterOrWithACycle() {
  var design = ModelDesignDocument.starter()
  design.nodes.remove(at: 1)
  design.edges = [.init(source: design.nodes[0].id, target: design.nodes[1].id)]
  #expect(ModelDesignValidator.validate(design).issues.contains {
    $0.message == "Training needs at least one parameterized layer."
  })

  design = .starter()
  design.edges.append(.init(source: design.nodes[1].id, target: design.nodes[1].id))
  #expect(!ModelDesignValidator.validate(design).isValid)
}

@Test func mnistClassifierHasTenScoresAndKeepsTaskInCheckpointIdentity() throws {
  let design = ModelDesignDocument.mnistStarter()
  let report = ModelDesignValidator.validate(design)
  #expect(report.isValid)
  #expect(report.shapes[design.nodes.last!.id] == [10])
  let source = try ModelPythonExporter.modelSource(design)
  #expect(source.contains("OUTPUT_NAME = \"scores\""))
  #expect(source.contains("nn.Conv2d"))
  #expect(source.contains("nn.Linear"))

  var altered = design
  altered.training.epochs = 20
  #expect(try ModelDesignJSON.architectureSHA256(altered)
    == ModelDesignJSON.architectureSHA256(design))
  altered.training.task = .pairedImages
  #expect(try ModelDesignJSON.architectureSHA256(altered)
    != ModelDesignJSON.architectureSHA256(design))
  #expect(!ModelDesignValidator.validate(altered).isValid)
}
