part of xmi;

/// Build a UModel from json representation of XMI
class JsonUModelBuilder {
  JsonUModelBuilder(
    this.srcJsonFile
  ) {

  }
  
  /// Path to json input file
  final String srcJsonFile;
  /// Data in Map format from parsed json
  Map _modelData;
  Map<String, dynamic> _itemMap = {};
  /// Map of items indexed by xmi:id
  Map<String, dynamic> get itemMap => _itemMap;
  Map<String, String> _sigToOwner = {};
  /// Map of id of signature to its owner
  Map<String, String> get sigToOwner => _sigToOwner;

// custom <class JsonUModelBuilder>

  String xmiType(Map map) => map["xmi:type"];

  List asList(dynamic entry) => 
    (entry is Map)? [ entry ] :
    (entry is List)? entry :
    [];

  List filterPackagedElementsBy(Map elements, String type) {
    List results = [];
    if(elements.containsKey("packagedElement")) {
      results = asList(elements['packagedElement']).where((e) => xmiType(e) == type).toList();
    }
    return results;
  }

  List filterOwnedAttributesBy(Map owner, String type) {
    List results = [];
    if(owner.containsKey("ownedAttribute")) {
      results = asList(owner['ownedAttribute']).where((e) => xmiType(e) == type).toList();
    }
    return results;
  }

  addComment(dynamic target, Map map) {
    if(map.containsKey("ownedComment")) {
      Map comment = map["ownedComment"];
      target.comment = new UComment(comment["xmi:id"])..body = comment["body"];
      _itemMap[target.id] = target;
    }
  }

  addProperties(dynamic target, Map map) {
    final RegExp bogusId = new RegExp(r"^\d");
    filterOwnedAttributesBy(map, "uml:Property").forEach((attribute) {
      String propName = attribute['name'];
      if(propName.contains(bogusId)) {
        propName = 'e_'+propName;
      }
      UProperty property = new UProperty(attribute['xmi:id'])
        ..name = propName
        ..type = attribute['type']
        ..visibility = attribute['visibility']
        ..aggregation = attribute['aggregation'];
      addComment(property, attribute);
      target.properties.add(property);
      _itemMap[property.id] = property;
    });
  }

  addTemplBindings(dynamic target, Map map) {
    if(map.containsKey("templateBinding")) {
      Map bindingEntry = map['templateBinding'];
      UTemplBinding binding = new UTemplBinding(bindingEntry['xmi:id'])
        ..signatureId = bindingEntry['signature'];
      target.templBinding = binding;
      List substs = asList(bindingEntry["parameterSubstitution"]).where((e) => 
            xmiType(e) == "uml:TemplateParameterSubstitution").toList();
      substs.forEach((subst) {
        UTemplParmSubst ts = new UTemplParmSubst(subst['xmi:id'])
          ..formalId = subst['formal']
          ..actualId = subst['actual'];
        binding.templParmSubsts.add(ts);
        _itemMap[ts.id] = ts;
      });      
      _itemMap[binding.id] = binding;
    }
  }

  addTemplSig(dynamic target, Map map) {
    if(map.containsKey("ownedTemplateSignature")) {
      Map sigEntry = map['ownedTemplateSignature'];
      UTemplSig sig = new UTemplSig(sigEntry['xmi:id']);
      target.templSig = sig;

      if(sigEntry.containsKey("ownedParameter")) {
        List parms = asList(sigEntry["ownedParameter"]).where((e) => 
            xmiType(e) == "uml:ClassifierTemplateParameter").toList();
        parms.forEach((parmEntry) {
          UClassifierTemplParm tp = new UClassifierTemplParm(parmEntry['xmi:id'])
            ..name = parmEntry['ownedParameteredElement']['name']
            ..type = parmEntry['ownedParameteredElement']['xmi:type']
            ..allowSubstitutable = parmEntry['allowSubstitutable'] == 'true';
          sig.parms.add(tp);
          _itemMap[tp.id] = tp;
        });
      }

      _itemMap[sig.id] = sig;
      _sigToOwner[sig.id] = target.id;
    }
  }

  addPackages(dynamic target, Map map) {
    filterPackagedElementsBy(map, "uml:Package").forEach((element) {
      String pkgName = element['name'];
      UPackage pkg = new UPackage(element['xmi:id'])
        ..parentPackageId = target.id
        ..path = (new List.from(target.path)..add(pkgName))
        ..name = pkgName;
      addComment(pkg, element);
      target.packages.add(pkg);
      addPackages(pkg, element);
      _itemMap[pkg.id] = pkg;
    });
    filterPackagedElementsBy(map, "uml:PrimitiveType").forEach((element) {
      UPrimitiveType primitive = new UPrimitiveType(element['xmi:id'])..name = element['name'];
      target.primitiveTypes.add(primitive);
      _itemMap[primitive.id] = primitive;
    });
    filterPackagedElementsBy(map, "uml:Class").forEach((element) {
      UClass klass = new UClass(element['xmi:id'])..name = element['name'];
      addComment(klass, element);
      addProperties(klass, element);
      addTemplBindings(klass, element);
      addTemplSig(klass, element);
      target.classes.add(klass);
      _itemMap[klass.id] = klass;
    });
    filterPackagedElementsBy(map, "uml:Enumeration").forEach((element) {
      UEnumeration enum_ = new UEnumeration(element['xmi:id'])..name = element['name'];
      addComment(enum_, element);
      addProperties(enum_, element);
      target.enums.add(enum_);
      _itemMap[enum_.id] = enum_;
    });
  }

  UPackage buildRootPackage(Map map) {
    UPackage pkg = new UPackage(map["xmi:id"])..name = map["name"];
    addComment(pkg, map);
    addPackages(pkg, map);
    _itemMap[pkg.id] = pkg;
    return pkg;
  }

  UModel buildModel() {
    String contents = new File(srcJsonFile).readAsStringSync();
    /// Tricky: Altova includes windowsee end of lines
    contents = contents.replaceAll(r'\r', r'\n');
    Map contentMap = JSON.parse(contents);
    _modelData = contentMap["XMI"]["Model"];

    UModel model = new UModel();
    model.root = buildRootPackage(_modelData);
    model._itemMap = itemMap;

    ///////////////////////////////////////////////////////////////////////////
    // Tricky part here: A template class owns a template signature and has a
    // name. A template instantiation has no name, but has a template binding
    // which has reference to the template signature of the template class it is
    // parameterizing. So, patch names keeping our naming convention:
    //
    // list<String> => list_of_string
    // j_map<String> => j_map_of_string
    //
    ///////////////////////////////////////////////////////////////////////////
    model._itemMap.forEach((k,v) {
      if(v is UClass && v.name == null) {
        assert(v.templBinding != null);
        UClass owningClass = _itemMap[_sigToOwner[v.templBinding.signatureId]];
        List parms = [];
        v.templBinding.templParmSubsts.forEach((subst) {
          var parmType = _itemMap[subst.actualId].name;
          parms.add(parmType);
        });
        v.name = "${owningClass.name}_of_${parms.join('_')}";
      }
    });

    return model;
  }

// end <class JsonUModelBuilder>
}

class UModel {
  UPackage root;
  Map<String, dynamic> _itemMap = {};
  /// Map of items indexed by xmi:id
  Map<String, dynamic> get itemMap => _itemMap;

// custom <class UModel>

  UClass class_(String id) => _itemMap[id];
  UEnumeration enum_(String id) => _itemMap[id];
  UComment comment(String id) => _itemMap[id];
  UDependency dependency(String id) => _itemMap[id];
  UPackage package(String id) => _itemMap[id];
  UProfile profile(String id) => _itemMap[id];
  UStereotype stereotype(String id) => _itemMap[id];
  UTemplBinding templBinding(String id) => _itemMap[id];
  UTemplParmSubst templParmSubst(String id) => _itemMap[id];
  UClassifierTemplParm classifierTemplParm(String id) => _itemMap[id];
  UTemplSig templSig(String id) => _itemMap[id];

  get classes => _itemMap.values.where((v) => v is UClass);
  get enums => _itemMap.values.where((v) => v is UEnumeration);
  get comments => _itemMap.values.where((v) => v is UComment);
  get packages => _itemMap.values.where((v) => v is UPackage);

// end <class UModel>

  Map toJson() {
    return {
    "root": EBISU_UTILS.toJson(root),
    "itemMap": EBISU_UTILS.toJson(_itemMap),
    // TODO: "UModel": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "root": EBISU_UTILS.randJson(_randomJsonGenerator, UPackage.randJson),
    "itemMap":
       EBISU_UTILS.randJsonMap(_randomJsonGenerator,
        () => dynamic.randJson(),
        "itemMap"),
    };
  }


  static UModel fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UModel result = new UModel();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UModel fromJsonMap(Map jsonMap) {
    UModel result = new UModel();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    root = (jsonMap["root"] is Map)?
      UPackage.fromJsonMap(jsonMap["root"]) :
      UPackage.fromJson(jsonMap["root"]);
    // itemMap map of <String, dynamic>
    itemMap = { };
    jsonMap["itemMap"].forEach((k,v) {
      _itemMap[k] = dynamic.fromJsonMap(v);
    });
  }
}

class UClass {
  UClass(
    this._id
  ) {

  }
  
  UClass._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml class
  String get id => _id;
  /// Name for this uml class
  String name;
  /// Comment (ownedComment) of this uml class
  UComment comment;
  /// Properties of this uml class
  List<UProperty> properties = [];
  UTemplBinding templBinding;
  UTemplSig templSig;

// custom <class UClass>

// end <class UClass>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    "comment": EBISU_UTILS.toJson(comment),
    "properties": EBISU_UTILS.toJson(properties),
    "templBinding": EBISU_UTILS.toJson(templBinding),
    "templSig": EBISU_UTILS.toJson(templSig),
    // TODO: "UClass": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "comment": EBISU_UTILS.randJson(_randomJsonGenerator, UComment.randJson),
    "properties":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UProperty.randJson()),
    "templBinding": EBISU_UTILS.randJson(_randomJsonGenerator, UTemplBinding.randJson),
    "templSig": EBISU_UTILS.randJson(_randomJsonGenerator, UTemplSig.randJson),
    };
  }


  static UClass fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UClass result = new UClass._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UClass fromJsonMap(Map jsonMap) {
    UClass result = new UClass._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
    comment = (jsonMap["comment"] is Map)?
      UComment.fromJsonMap(jsonMap["comment"]) :
      UComment.fromJson(jsonMap["comment"]);
    // properties list of UProperty
    properties = new List<UProperty>();
    jsonMap["properties"].forEach((v) {
      properties.add(UProperty.fromJsonMap(v));
    });
    templBinding = (jsonMap["templBinding"] is Map)?
      UTemplBinding.fromJsonMap(jsonMap["templBinding"]) :
      UTemplBinding.fromJson(jsonMap["templBinding"]);
    templSig = (jsonMap["templSig"] is Map)?
      UTemplSig.fromJsonMap(jsonMap["templSig"]) :
      UTemplSig.fromJson(jsonMap["templSig"]);
  }
}

class UComment {
  UComment(
    this._id
  ) {

  }
  
  UComment._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml comment
  String get id => _id;
  /// Text of the comment
  String body;

// custom <class UComment>

  String toString() => body;

// end <class UComment>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "body": EBISU_UTILS.toJson(body),
    // TODO: "UComment": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "body": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UComment fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UComment result = new UComment._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UComment fromJsonMap(Map jsonMap) {
    UComment result = new UComment._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    body = jsonMap["body"];
  }
}

class UDependency {
  UDependency(
    this._id
  ) {

  }
  
  UDependency._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml dependency
  String get id => _id;
  String supplier;
  String client;

// custom <class UDependency>
// end <class UDependency>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "supplier": EBISU_UTILS.toJson(supplier),
    "client": EBISU_UTILS.toJson(client),
    // TODO: "UDependency": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "supplier": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "client": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UDependency fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UDependency result = new UDependency._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UDependency fromJsonMap(Map jsonMap) {
    UDependency result = new UDependency._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    supplier = jsonMap["supplier"];
    client = jsonMap["client"];
  }
}

class UEnumeration {
  UEnumeration(
    this._id
  ) {

  }
  
  UEnumeration._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml enumeration
  String get id => _id;
  /// Name for this uml enumeration
  String name;
  /// Properties of this uml enumeration
  List<UProperty> properties = [];
  /// Comment (ownedComment) of this uml enumeration
  UComment comment;

// custom <class UEnumeration>
// end <class UEnumeration>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    "properties": EBISU_UTILS.toJson(properties),
    "comment": EBISU_UTILS.toJson(comment),
    // TODO: "UEnumeration": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "properties":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UProperty.randJson()),
    "comment": EBISU_UTILS.randJson(_randomJsonGenerator, UComment.randJson),
    };
  }


  static UEnumeration fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UEnumeration result = new UEnumeration._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UEnumeration fromJsonMap(Map jsonMap) {
    UEnumeration result = new UEnumeration._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
    // properties list of UProperty
    properties = new List<UProperty>();
    jsonMap["properties"].forEach((v) {
      properties.add(UProperty.fromJsonMap(v));
    });
    comment = (jsonMap["comment"] is Map)?
      UComment.fromJsonMap(jsonMap["comment"]) :
      UComment.fromJson(jsonMap["comment"]);
  }
}

class UPackage {
  UPackage(
    this._id
  ) {

  }
  
  UPackage._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml package
  String get id => _id;
  /// Name for this uml package
  String name;
  /// Comment (ownedComment) of this uml package
  UComment comment;
  List<UClass> classes = [];
  List<UEnumeration> enums = [];
  List<UPrimitiveType> primitiveTypes = [];
  List<UPackage> packages = [];
  String parentPackageId;
  /// Path to package as list of strings
  List<String> path = [];

// custom <class UPackage>
// end <class UPackage>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    "comment": EBISU_UTILS.toJson(comment),
    "classes": EBISU_UTILS.toJson(classes),
    "enums": EBISU_UTILS.toJson(enums),
    "primitiveTypes": EBISU_UTILS.toJson(primitiveTypes),
    "packages": EBISU_UTILS.toJson(packages),
    "parentPackageId": EBISU_UTILS.toJson(parentPackageId),
    "path": EBISU_UTILS.toJson(path),
    // TODO: "UPackage": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "comment": EBISU_UTILS.randJson(_randomJsonGenerator, UComment.randJson),
    "classes":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UClass.randJson()),
    "enums":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UEnumeration.randJson()),
    "primitiveTypes":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UPrimitiveType.randJson()),
    "packages":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UPackage.randJson()),
    "parentPackageId": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "path":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => EBISU_UTILS.randJson(_randomJsonGenerator, String)),
    };
  }


  static UPackage fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UPackage result = new UPackage._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UPackage fromJsonMap(Map jsonMap) {
    UPackage result = new UPackage._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
    comment = (jsonMap["comment"] is Map)?
      UComment.fromJsonMap(jsonMap["comment"]) :
      UComment.fromJson(jsonMap["comment"]);
    // classes list of UClass
    classes = new List<UClass>();
    jsonMap["classes"].forEach((v) {
      classes.add(UClass.fromJsonMap(v));
    });
    // enums list of UEnumeration
    enums = new List<UEnumeration>();
    jsonMap["enums"].forEach((v) {
      enums.add(UEnumeration.fromJsonMap(v));
    });
    // primitiveTypes list of UPrimitiveType
    primitiveTypes = new List<UPrimitiveType>();
    jsonMap["primitiveTypes"].forEach((v) {
      primitiveTypes.add(UPrimitiveType.fromJsonMap(v));
    });
    // packages list of UPackage
    packages = new List<UPackage>();
    jsonMap["packages"].forEach((v) {
      packages.add(UPackage.fromJsonMap(v));
    });
    parentPackageId = jsonMap["parentPackageId"];
    // path list of String
    path = new List<String>();
    jsonMap["path"].forEach((v) {
      path.add(String.fromJsonMap(v));
    });
  }
}

class UPrimitiveType {
  UPrimitiveType(
    this._id
  ) {

  }
  
  UPrimitiveType._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml primitive type
  String get id => _id;
  /// Name for this uml primitive type
  String name;

// custom <class UPrimitiveType>
// end <class UPrimitiveType>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    // TODO: "UPrimitiveType": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UPrimitiveType fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UPrimitiveType result = new UPrimitiveType._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UPrimitiveType fromJsonMap(Map jsonMap) {
    UPrimitiveType result = new UPrimitiveType._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
  }
}

class UProperty {
  UProperty(
    this._id
  ) {

  }
  
  UProperty._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml property
  String get id => _id;
  /// Name for this uml property
  String name;
  /// Comment (ownedComment) of this uml property
  UComment comment;
  /// Id for the type of this property
  String type;
  String visibility;
  String aggregation;

// custom <class UProperty>
// end <class UProperty>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    "comment": EBISU_UTILS.toJson(comment),
    "type": EBISU_UTILS.toJson(type),
    "visibility": EBISU_UTILS.toJson(visibility),
    "aggregation": EBISU_UTILS.toJson(aggregation),
    // TODO: "UProperty": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "comment": EBISU_UTILS.randJson(_randomJsonGenerator, UComment.randJson),
    "type": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "visibility": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "aggregation": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UProperty fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UProperty result = new UProperty._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UProperty fromJsonMap(Map jsonMap) {
    UProperty result = new UProperty._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
    comment = (jsonMap["comment"] is Map)?
      UComment.fromJsonMap(jsonMap["comment"]) :
      UComment.fromJson(jsonMap["comment"]);
    type = jsonMap["type"];
    visibility = jsonMap["visibility"];
    aggregation = jsonMap["aggregation"];
  }
}

class UProfile {
  UProfile(
    this._id
  ) {

  }
  
  UProfile._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml profile
  String get id => _id;
  /// Name for this uml profile
  String name;

// custom <class UProfile>
// end <class UProfile>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    // TODO: "UProfile": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UProfile fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UProfile result = new UProfile._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UProfile fromJsonMap(Map jsonMap) {
    UProfile result = new UProfile._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
  }
}

class UStereotype {
  UStereotype(
    this._id
  ) {

  }
  
  UStereotype._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml stereotype
  String get id => _id;
  /// Name for this uml stereotype
  String name;
  /// Properties of this uml class
  List<UProperty> properties = [];

// custom <class UStereotype>
// end <class UStereotype>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "name": EBISU_UTILS.toJson(name),
    "properties": EBISU_UTILS.toJson(properties),
    // TODO: "UStereotype": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "properties":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UProperty.randJson()),
    };
  }


  static UStereotype fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UStereotype result = new UStereotype._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UStereotype fromJsonMap(Map jsonMap) {
    UStereotype result = new UStereotype._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    name = jsonMap["name"];
    // properties list of UProperty
    properties = new List<UProperty>();
    jsonMap["properties"].forEach((v) {
      properties.add(UProperty.fromJsonMap(v));
    });
  }
}

class UTemplBinding {
  UTemplBinding(
    this._id
  ) {

  }
  
  UTemplBinding._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml template binding
  String get id => _id;
  /// Id of the signature of this template binding
  String signatureId;
  /// Parameter substitutions for this binding
  List<UTemplParmSubst> templParmSubsts = [];

// custom <class UTemplBinding>
// end <class UTemplBinding>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "signatureId": EBISU_UTILS.toJson(signatureId),
    "templParmSubsts": EBISU_UTILS.toJson(templParmSubsts),
    // TODO: "UTemplBinding": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "signatureId": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "templParmSubsts":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UTemplParmSubst.randJson()),
    };
  }


  static UTemplBinding fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UTemplBinding result = new UTemplBinding._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UTemplBinding fromJsonMap(Map jsonMap) {
    UTemplBinding result = new UTemplBinding._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    signatureId = jsonMap["signatureId"];
    // templParmSubsts list of UTemplParmSubst
    templParmSubsts = new List<UTemplParmSubst>();
    jsonMap["templParmSubsts"].forEach((v) {
      templParmSubsts.add(UTemplParmSubst.fromJsonMap(v));
    });
  }
}

class UTemplParmSubst {
  UTemplParmSubst(
    this._id
  ) {

  }
  
  UTemplParmSubst._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml template parameter substitution
  String get id => _id;
  /// Id of the formal type being substituted
  String formalId;
  /// Id of the actual type being substituted
  String actualId;

// custom <class UTemplParmSubst>
// end <class UTemplParmSubst>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "formalId": EBISU_UTILS.toJson(formalId),
    "actualId": EBISU_UTILS.toJson(actualId),
    // TODO: "UTemplParmSubst": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "formalId": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "actualId": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UTemplParmSubst fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UTemplParmSubst result = new UTemplParmSubst._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UTemplParmSubst fromJsonMap(Map jsonMap) {
    UTemplParmSubst result = new UTemplParmSubst._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    formalId = jsonMap["formalId"];
    actualId = jsonMap["actualId"];
  }
}

class UClassifierTemplParm {
  UClassifierTemplParm(
    this._id
  ) {

  }
  
  UClassifierTemplParm._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml classifier template parameter
  String get id => _id;
  bool allowSubstitutable = false;
  String name;
  String type;

// custom <class UClassifierTemplParm>
// end <class UClassifierTemplParm>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "allowSubstitutable": EBISU_UTILS.toJson(allowSubstitutable),
    "name": EBISU_UTILS.toJson(name),
    "type": EBISU_UTILS.toJson(type),
    // TODO: "UClassifierTemplParm": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "allowSubstitutable": EBISU_UTILS.randJson(_randomJsonGenerator, bool),
    "name": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "type": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    };
  }


  static UClassifierTemplParm fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UClassifierTemplParm result = new UClassifierTemplParm._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UClassifierTemplParm fromJsonMap(Map jsonMap) {
    UClassifierTemplParm result = new UClassifierTemplParm._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    allowSubstitutable = jsonMap["allowSubstitutable"];
    name = jsonMap["name"];
    type = jsonMap["type"];
  }
}

class UTemplSig {
  UTemplSig(
    this._id
  ) {

  }
  
  UTemplSig._json(

  ) {

  }
  
  final String _id;
  /// Id for this uml template signature
  String get id => _id;
  List<UClassifierTemplParm> parms = [];

// custom <class UTemplSig>
// end <class UTemplSig>

  Map toJson() {
    return {
    "id": EBISU_UTILS.toJson(_id),
    "parms": EBISU_UTILS.toJson(parms),
    // TODO: "UTemplSig": super.toJson(),
    };
  }

  static Map randJson() {
    return {
    "id": EBISU_UTILS.randJson(_randomJsonGenerator, String),
    "parms":
       EBISU_UTILS.randJson(_randomJsonGenerator, [],
        () => UClassifierTemplParm.randJson()),
    };
  }


  static UTemplSig fromJson(String json) {
    Map jsonMap = JSON.parse(json);
    UTemplSig result = new UTemplSig._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  static UTemplSig fromJsonMap(Map jsonMap) {
    UTemplSig result = new UTemplSig._json();
    result._fromJsonMapImpl(jsonMap);
    return result;
  }

  void _fromJsonMapImpl(Map jsonMap) {
    _id = jsonMap["id"];
    // parms list of UClassifierTemplParm
    parms = new List<UClassifierTemplParm>();
    jsonMap["parms"].forEach((v) {
      parms.add(UClassifierTemplParm.fromJsonMap(v));
    });
  }
}
// custom <part model>
// end <part model>

