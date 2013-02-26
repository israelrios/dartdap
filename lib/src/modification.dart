library modification;

class Modification {
  const int ADD = 0;
  const int DELETE = 1;
  const int REPLACE = 2;
  const int INCREMENT = 3;

  String _attrName;

  // attr values
  List _values = new List();

  int _operation;

  String get attributeName => _attrName;
  int get operation => _operation;
  List get values => _values;

  Modification(this._operation, this._attrName, this._values);

  Modification.replace(this._attrName, this._values ) {
    _operation = REPLACE;
  }

  Modification.add(this._attrName, this._values) {
    _operation = ADD;
  }

  Modification.increment(this._attrName, this._values) {
    _operation = INCREMENT;
  }

  Modification.delete(this._attrName, this._values) {
    _operation = DELETE;
  }

  //  ["r","sn", "Mickey Mouse"]
  static List<Modification> modList( List<List> modList ) {
    var list = new List();
    modList.forEach(  (x) {
      assert( x.length == 3);
      String op = x[0];
      var attr = x[1];
      var vals = x[2];
      switch (op) {
        case "a" :
          list.add( new Modification.add(attr,vals));
          break;
      }
    });
    return list;
  }

}
