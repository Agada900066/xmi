part of xmi_polymer;

/// Maps a UModel to a collection of components
class ModelMapping {
  ModelMapping(
    this.model,
    this.id
  ) {

  }
  
  /// UML Model source for components
  UModel model;
  /// Id for this component library
  Id id;

  // custom <class ModelMapping>

  Component _makeComponent(cls, [String prefix]) {
    Component result = component(cls.name)..prefix = prefix;
    Set imports = new Set();
    var parts = new List();
    RegExp isListRe = new RegExp('^list_of');
    RegExp isMapRe = new RegExp('^j_map_of');
    RegExp referenceType = new RegExp(r'^(?:j_map_of_|list_of_)(\w+)$');
    Id listOfComponentId = (prefix == null)? 
      new Id('list_of') : new Id('${prefix}_list_of');
    Id jMapOfComponentId = (prefix == null)? 
      new Id('j_map_of') : new Id('${prefix}_j_map_of');
    String listOf = listOfComponentId.emacs;
    String listOfHtml = './' + new Id('list_of').snake + '.html';
    String jMapOf = jMapOfComponentId.emacs;
    String jMapOfHtml = './' + new Id('j_map_of').snake + '.html';

    Id _componentNameId(String typeName) {
      String result;
      var match = referenceType.firstMatch(typeName);
      if(match != null) {
        result = match.group(1);
      } else {
        result = typeName;
      }
      return new Id(result);
    };

    cls.properties.forEach((property) {

      String propertyInputHtml;
      var propertyItem = model.itemMap[property];
      var itemType = model.itemMap[property.type];

      if(itemType is UClass) {
        var componentNameId = _componentNameId(itemType.name);
        var componentName = componentNameId.emacs;
        String prefixedName = (prefix != null)?
          new Id('${prefix}_${componentNameId.snake}').emacs: componentName;

        String spec = '<${prefixedName}></${prefixedName}>';
        if(itemType.name.contains(isListRe)) {
          propertyInputHtml = '<${listOf}>$spec</${listOf}>';
          imports.add(listOfHtml);
        } else if(itemType.name.contains(isMapRe)) {
          propertyInputHtml = '<${jMapOf}>$spec</${jMapOf}>';
          imports.add(jMapOfHtml);
        } else {
          propertyInputHtml = spec;
        }
        imports.add("./${componentNameId.snake}.html");
      } else if(itemType is UEnumeration) {
        propertyInputHtml = '<input type="text" name="${itemType.name}">';
      } else if(itemType is UPrimitiveType) {
        propertyInputHtml = '<input type="text" name="${itemType.name}">';
      } else {
        throw "Add support for type ${itemType}";
      }

      parts.add('''
<div>
  <label>${property.name}</label>
  ${propertyInputHtml}
</div>
''');
    });
    
    return result
      ..templateFragment = '${parts.join("\n")}'
      ..htmlImports = imports.toList();
  }

  ComponentLibrary makeComponentLibrary([String prefix]) {
    var ignored = new RegExp('^(?:j_map|list)');
    ComponentLibrary lib = new ComponentLibrary(id)
      ..doc = 'Collection of components useful for modeling the data associated with a family'
      ..prefix = prefix
      ..components = model.classes
      .where((cls) => !cls.name.contains(ignored))
      .map((cls) => _makeComponent(cls, prefix)).toList();

    lib.components.add(component('list_of'));
    lib.components.add(component('j_map_of'));

    return lib;
  }

  // end <class ModelMapping>
}
// custom <part model_mapping>
// end <part model_mapping>

