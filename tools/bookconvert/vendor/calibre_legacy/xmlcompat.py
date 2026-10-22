# GPL-3.0-only. Small stdlib tree adapter for the retained read-only decoder.
# Only the two XPath forms used by the retained calibre classes are supported.
# This avoids a new binary XML dependency in either Windows architecture.
import re
import xml.etree.ElementTree as ET

XMLSyntaxError=ET.ParseError


class Element(ET.Element):
    def __init__(self,tag,attrib=None,**extra):
        super().__init__(tag,attrib or {},**extra);self._parent=None
    def append(self,element):
        super().append(element)
        if isinstance(element,Element):element._parent=self
    def insert(self,index,element):
        super().insert(index,element)
        if isinstance(element,Element):element._parent=self
    def remove(self,element):
        super().remove(element)
        if isinstance(element,Element):element._parent=None
    def getparent(self):return self._parent
    def makeelement(self,tag,attrib=None,**extra):return Element(tag,attrib,**extra)
    def xpath(self,expression,**variables):
        if expression.startswith('descendant::'):
            return [node for node in self.iter(expression[12:]) if node is not self]
        if expression=='//*[local-name()=$name]':
            return [node for node in self.iter() if isinstance(node.tag,str) and node.tag.rsplit('}',1)[-1]==variables['name']]
        raise ValueError('Unsupported legacy tree query: '+expression)


class XSLTExtension: pass
class HTMLParser:
    def __init__(self,**kwargs):pass


def XMLParser(**kwargs):return ET.XMLParser(target=ET.TreeBuilder(element_factory=Element))


def fromstring(data,parser=None):
    if isinstance(parser,HTMLParser):
        import html5lib
        return html5lib.parse(data,treebuilder='etree',namespaceHTMLElements=False)
    if re.search(br'<!\s*(DOCTYPE|ENTITY)\b',data,re.I):
        raise XMLSyntaxError('External declarations are not used by the legacy decoder')
    root=ET.fromstring(data,parser=parser or XMLParser())
    for parent in root.iter():
        for child in parent:
            if isinstance(child,Element):child._parent=parent
    return root


def SubElement(parent,tag,attrib=None,**extra):
    element=Element(tag,attrib,**extra);parent.append(element);return element


def tostring(element,**kwargs):return ET.tostring(element,**kwargs)
def clone(element):return fromstring(tostring(element,encoding='utf-8'))


class QName:
    def __init__(self,element):self.localname=element.tag.rsplit('}',1)[-1]
