package agent_store

import agent_domain.*

import std.collection.*
import std.convert.*
import stdx.crypto.digest.SHA256

// Pure mechanical JSON scanning, without application enums, SQL, identity,
// paths, grants or Sources. Only an actual operator-frozen data-access owner
// may choose a projection plan and expose its output. A result is descriptive
// data; neither its digest nor a caller's completion flag authorizes a read.
// Same byte definition as String.trimAscii: HT/LF/VT/FF/CR/space only.
func liveProposalAsciiWhitespace296(byte:Byte):Bool{byte==0x20 || (byte>=0x09 && byte<=0x0D)}
class LiveProposalProjectionRule296 {
    public let path:Array<String>
    public let prefixBytes:Int64
    public let includePrefix:Bool
    public let asciiTrimmedLength:Bool
    init(path:Array<String>,prefixBytes!:Int64=0,includePrefix!:Bool=false,asciiTrimmedLength!:Bool=false){
        if(path.isEmpty() || path.size>32 || prefixBytes<0 || prefixBytes>64 || (!includePrefix && prefixBytes!=0)){
            throw LogicalJsonPayloadError("JSON projection rule is outside its bounded descriptive shape")}
        for(component in path where component==""){throw LogicalJsonPayloadError("JSON projection path is empty")}
        this.path=path;this.prefixBytes=prefixBytes;this.includePrefix=includePrefix;this.asciiTrimmedLength=asciiTrimmedLength
    }
}
class LiveProposalProjectionComparison296 {
    public let path:Array<String>
    public let expected:String
    public let asciiTrim:Bool
    init(path:Array<String>,expected:String,asciiTrim!:Bool=false){this.path=path;this.expected=expected;this.asciiTrim=asciiTrim}
}
class LiveProposalProjectedField296 {
    let rule:LiveProposalProjectionRule296
    var kind="missing"
    var bytes:Int64=0
    let prefix=ArrayList<Byte>()
    var stopped=false
    private var firstNonTrim:Int64= -1
    private var lastNonTrimEnd:Int64=0
    init(rule:LiveProposalProjectionRule296){this.rule=rule}
    func scalar(value:Array<Byte>):Unit{
        if(rule.asciiTrimmedLength && (value.size!=1 || !liveProposalAsciiWhitespace296(value[0]))){
            if(firstNonTrim<0){firstNonTrim=bytes};lastNonTrimEnd=bytes+value.size}
        bytes+=value.size
        if(!stopped && rule.includePrefix){
            if(prefix.size+value.size<=rule.prefixBytes){prefix.add(all:value)}else{stopped=true}}
    }
    func ascii(byte:Byte):Unit{
        if(rule.asciiTrimmedLength && !liveProposalAsciiWhitespace296(byte)){
            if(firstNonTrim<0){firstNonTrim=bytes};lastNonTrimEnd=bytes+1}
        bytes++
        if(!stopped && rule.includePrefix){
            if(prefix.size<rule.prefixBytes){prefix.add(byte)}else{stopped=true}}
    }
    func value():AgentValue{
        let fields=ArrayList<ValueField>()
        fields.add(ValueField("path",listValue(rule.path.map{part=>textValue(part)})))
        fields.add(ValueField("type",textValue(kind)));fields.add(ValueField("bytes",integerValue(bytes)))
        if(rule.includePrefix){fields.add(ValueField("prefix",textValue(String.fromUtf8(prefix.toArray()))))}
        if(rule.asciiTrimmedLength){fields.add(ValueField("ascii_trimmed_bytes",integerValue(
            if(kind!="string" || firstNonTrim<0){0}else{lastNonTrimEnd-firstNonTrim})))}
        objectValue(fields.toArray())
    }
}
class LiveProposalComparison296 {
    let rule:LiveProposalProjectionComparison296
    var offset:Int64=0
    var matches=false
    var seen=false
    init(rule:LiveProposalProjectionComparison296){this.rule=rule}
    func begin(kind:String):Unit{seen=true;matches=kind=="string";offset=0}
    func scalar(value:Array<Byte>):Unit{
        if(rule.asciiTrim && value.size==1){ascii(value[0]);return}
        if(matches){
            if(value.size>rule.expected.size-offset){matches=false}
            else{for(index in 0..value.size){if(value[index]!=rule.expected[offset+index]){matches=false}}}}
        offset+=value.size
    }
    func ascii(byte:Byte):Unit{
        if(rule.asciiTrim && liveProposalAsciiWhitespace296(byte) && (offset==0 || offset>=rule.expected.size)){return}
        if(matches && (offset>=rule.expected.size || rule.expected[offset]!=byte)){matches=false};offset++
    }
    func finish():Unit{matches=matches && seen && offset==rule.expected.size}
}
class LiveProposalFrame296 {
    let object:Bool
    let depth:Int64
    let matches:Array<Int64>
    let comparisons:Array<Int64>
    let path296:Array<String>
    let start296:Int64
    let keys=HashSet<String>()
    var phase:Int64=0
    var key=""
    var index:Int64=0
    var keyBytes:Int64=0
    init(object:Bool,depth:Int64,matches:Array<Int64>,comparisons:Array<Int64>,path:Array<String>,start:Int64){
        this.object=object;this.depth=depth;this.matches=matches;this.comparisons=comparisons
        this.path296=path;this.start296=start}
}
class LiveProposalLocation296 {
    let depth:Int64
    let matches:Array<Int64>
    let comparisons:Array<Int64>
    init(depth:Int64,matches:Array<Int64>,comparisons:Array<Int64>){this.depth=depth;this.matches=matches;this.comparisons=comparisons}
}
class LiveProposalProjection296 {
    public let value:AgentValue
    // These stay with the trusted actual data-access owner. They are not
    // fields of the public projection sent for an unreadable payload.
    public let comparisonMatches:Array<Bool>
    init(value:AgentValue,matches:Array<Bool>){this.value=value;this.comparisonMatches=matches}
}
class LiveProposalScanner296 {
    private let owner:LogicalJsonOwnerReservation
    private let expectedBytes:Int64
    private let expectedDigest:String
    private let projectedSchema:String
    private let fields:Array<LiveProposalProjectedField296>
    private let comparisons:Array<LiveProposalComparison296>
    private let publicFields:Int64
    private let beginValue:(Array<String>,String,Int64)->Unit
    private let decodedScalar:(Array<String>,String,Array<Byte>)->Unit
    private let endValue:(Array<String>,String,Int64,Int64)->Unit
    private var position296:Int64=0
    private var selectedPath296:Array<String>=[]
    private var selectedKind296=""
    private var selectedStart296:Int64=0
    private let frames=ArrayList<LiveProposalFrame296>()
    private let hash=SHA256()
    private var offset:Int64=0
    private var root:Int64=0
    private var mode:Int64=0 // syntax/string/number/literal
    private var number:Int64=0
    private var literal=""
    private var literalOffset:Int64=0
    private var key=false
    private let keyBytes=ArrayList<Byte>()
    private var keyBytesRetained:Int64=0
    private var keysRetained:Int64=0
    private var selected:Array<Int64>=[]
    private var selectedComparisons:Array<Int64>=[]
    private var stringEscape=false
    private var unicodeDigits:Int64=0
    private var unicode:UInt32=0
    private var high:UInt32=0
    private var lowStep:Int64=0
    private var utf8Remaining:Int64=0
    private var utf8Scalar:UInt32=0
    private var utf8Minimum:UInt32=0
    private let utf8=ArrayList<Byte>()
    private var complete=false
    init(bytes:Int64,digest:String,owner:LogicalJsonOwnerReservation,
        begin:(Array<String>,String,Int64)->Unit,
        scalar:(Array<String>,String,Array<Byte>)->Unit,
        end:(Array<String>,String,Int64,Int64)->Unit){
        if(bytes<1 || !httpIntentDigest(digest)){throw LogicalJsonPayloadError("live proposal exact stream extent is invalid")}
        owner.ensureRetainedPeak(2097152)
        this.expectedBytes=bytes;this.expectedDigest=digest;this.owner=owner
        this.beginValue=begin;this.decodedScalar=scalar;this.endValue=end
        this.projectedSchema="axyndra.json-field-projection/v1"
        this.fields=[LiveProposalProjectedField296(LiveProposalProjectionRule296(["__syntax_only__"]))]
        this.comparisons=[];this.publicFields=1
        charge(0)
    }
    private func invalid(message:String):Nothing{throw LogicalJsonPayloadError(message)}
    private func charge(extra:Int64):Unit{
        if(extra<0 || keyBytesRetained>Int64.Max/16-keyBytes.size-extra || keysRetained>Int64.Max/1024){invalid("JSON projection ownership overflow")}
        var comparisonBytes:Int64=0
        for(value in comparisons){comparisonBytes+=value.rule.expected.size}
        owner.ensureRetainedPeak(2097152+(keyBytesRetained+keyBytes.size+extra)*16+keysRetained*1024+comparisonBytes*4)
    }
    private func top():LiveProposalFrame296{frames[frames.size-1]}
    private func begin(kind:String):LiveProposalLocation296{
        let matches=ArrayList<Int64>();let matchedComparisons=ArrayList<Int64>();var depth:Int64=0
        var path:Array<String>=[]
        if(frames.isEmpty()){
            if(root!=0){invalid("JSON has more than one root value")};root=1
            for(index in 0..fields.size){matches.add(index)}
            for(index in 0..comparisons.size){matchedComparisons.add(index)}
        }else{
            let parent=top();depth=parent.depth+1
            if((parent.object && parent.phase!=2) || (!parent.object && parent.phase!=0 && parent.phase!=2)){
                invalid("JSON value is outside its container grammar")}
            let component=if(parent.object){parent.key}else{parent.index.toString()}
            let selectedPath=ArrayList<String>();selectedPath.add(all:parent.path296);selectedPath.add(component)
            path=selectedPath.toArray()
            for(index in parent.matches){let path=fields[index].rule.path
                if(path.size>=depth && path[depth-1]==component){matches.add(index)}}
            for(index in parent.comparisons){let path=comparisons[index].rule.path
                if(path.size>=depth && path[depth-1]==component){matchedComparisons.add(index)}}
            parent.phase=if(parent.object){3}else{1};if(!parent.object){parent.index++}
        }
        let actualDepth=depth
        selected=matches.toArray().filter{index=>fields[index].rule.path.size==actualDepth}
        selectedComparisons=matchedComparisons.toArray().filter{index=>comparisons[index].rule.path.size==actualDepth}
        for(index in selected){if(fields[index].kind!="missing"){invalid("JSON projection encountered a duplicate path")};fields[index].kind=kind}
        for(index in selectedComparisons){comparisons[index].begin(kind)}
        selectedPath296=path;selectedKind296=kind;selectedStart296=position296
        beginValue(path,kind,position296)
        LiveProposalLocation296(depth,matches.toArray(),matchedComparisons.toArray())
    }
    private func scalarDone():Unit{
        endValue(selectedPath296,selectedKind296,selectedStart296,
            if(selectedKind296=="string"){position296+1}else{position296})
        selectedPath296=[];selectedKind296=""
        for(index in selectedComparisons){comparisons[index].finish()}
        mode=0;selected=[];selectedComparisons=[];if(frames.isEmpty()){root=2}
    }
    private func scalar(value:Array<Byte>):Unit{
        if(key){charge(value.size);keyBytes.add(all:value)}
        for(index in selected){fields[index].scalar(value)}
        for(index in selectedComparisons){comparisons[index].scalar(value)}
        if(!key){decodedScalar(selectedPath296,selectedKind296,value)}
    }
    private func ascii(byte:Byte):Unit{
        if(key){charge(1);keyBytes.add(byte)}
        for(index in selected){fields[index].ascii(byte)}
        for(index in selectedComparisons){comparisons[index].ascii(byte)}
        if(!key){decodedScalar(selectedPath296,selectedKind296,[byte])}
    }
    private func unicodeHex(byte:Byte):UInt32{
        if(byte>=b'0' && byte<=b'9'){return UInt32(byte-b'0')}
        if(byte>=b'a' && byte<=b'f'){return UInt32(byte-b'a')+10}
        if(byte>=b'A' && byte<=b'F'){return UInt32(byte-b'A')+10};invalid("JSON Unicode escape is invalid")
    }
    private func unicodeScalar(value:UInt32):Array<Byte>{
        if(value>0x10FFFF || (value>=0xD800 && value<=0xDFFF)){invalid("JSON Unicode scalar is invalid")}
        if(value<=0x7F){return [UInt8(value)]}
        if(value<=0x7FF){return [UInt8(0xC0|(value>>6)),UInt8(0x80|(value&0x3F))]}
        if(value<=0xFFFF){return [UInt8(0xE0|(value>>12)),UInt8(0x80|((value>>6)&0x3F)),UInt8(0x80|(value&0x3F))]}
        [UInt8(0xF0|(value>>18)),UInt8(0x80|((value>>12)&0x3F)),UInt8(0x80|((value>>6)&0x3F)),UInt8(0x80|(value&0x3F))]
    }
    private func beginString():Unit{
        key=!frames.isEmpty() && top().object && (top().phase==0 || top().phase==4)
        keyBytes.clear();selected=[];selectedComparisons=[]
        if(!key){let _=begin("string")}
        stringEscape=false;unicodeDigits=0;high=0;lowStep=0;utf8Remaining=0;utf8.clear();mode=1
    }
    private func stringByte(byte:Byte):Unit{
        if(utf8Remaining>0){
            if(byte<0x80 || byte>0xBF){invalid("JSON UTF8 continuation is invalid")}
            utf8Scalar=(utf8Scalar<<6)|UInt32(byte&0x3F);utf8.add(byte);utf8Remaining--
            if(utf8Remaining==0){
                if(utf8Scalar<utf8Minimum || utf8Scalar>0x10FFFF || (utf8Scalar>=0xD800 && utf8Scalar<=0xDFFF)){
                    invalid("JSON UTF8 scalar is invalid")}
                scalar(utf8.toArray());utf8.clear()};return
        }
        if(unicodeDigits>0){
            unicode=(unicode<<4)|unicodeHex(byte);unicodeDigits--
            if(unicodeDigits==0){
                if(high!=0){if(unicode<0xDC00 || unicode>0xDFFF){invalid("JSON low surrogate is invalid")}
                    scalar(unicodeScalar(0x10000+((high-0xD800)<<10)+(unicode-0xDC00)));high=0}
                else if(unicode>=0xD800 && unicode<=0xDBFF){high=unicode;lowStep=1}
                else{scalar(unicodeScalar(unicode))}}
            return
        }
        if(lowStep>0){
            if((lowStep==1 && byte!=b'\\') || (lowStep==2 && byte!=b'u')){invalid("JSON high surrogate has no complete low pair")}
            if(lowStep==1){lowStep=2}else{lowStep=0;unicode=0;unicodeDigits=4};return
        }
        if(stringEscape){
            stringEscape=false
            match(byte){case b'"' | b'\\' | b'/'=>scalar([byte])
                case b'b'=>scalar([UInt8(8)]);case b'f'=>scalar([UInt8(12)])
                case b'n'=>scalar([UInt8(10)]);case b'r'=>scalar([UInt8(13)]);case b't'=>scalar([UInt8(9)])
                case b'u'=>unicode=0;unicodeDigits=4
                case _=>invalid("JSON string escape is invalid")};return
        }
        if(byte==b'"'){
            if(key){
                charge(keyBytes.size+128);let value=String.fromUtf8(keyBytes.toArray())
                if(!top().keys.add(value)){invalid("JSON repeats an object key")}
                keyBytesRetained+=keyBytes.size;keysRetained++;top().keyBytes+=keyBytes.size
                top().key=value;top().phase=1
                keyBytes.clear();mode=0
            }else{scalarDone()};return
        }
        if(byte==b'\\'){stringEscape=true;return}
        if(byte<0x20){invalid("JSON string contains an unescaped control")}
        if(byte<0x80){ascii(byte);return}
        if(byte>=0xC2 && byte<=0xDF){utf8Remaining=1;utf8Scalar=UInt32(byte&0x1F);utf8Minimum=0x80}
        else if(byte>=0xE0 && byte<=0xEF){utf8Remaining=2;utf8Scalar=UInt32(byte&0x0F);utf8Minimum=0x800}
        else if(byte>=0xF0 && byte<=0xF4){utf8Remaining=3;utf8Scalar=UInt32(byte&0x07);utf8Minimum=0x10000}
        else{invalid("JSON UTF8 leading byte is invalid")};utf8.add(byte)
    }
    private func numberByte(byte:Byte):Unit{
        match(number){
            case 0=>if(byte==b'-'){number=1}else if(byte==b'0'){number=2}else if(byte>=b'1' && byte<=b'9'){number=3}else{invalid("JSON number starts incorrectly")}
            case 1=>if(byte==b'0'){number=2}else if(byte>=b'1' && byte<=b'9'){number=3}else{invalid("JSON minus has no integer")}
            case 2 | 3=>if(byte==b'.'){number=4}else if(byte==b'e' || byte==b'E'){number=6}
                else if(number==3 && byte>=b'0' && byte<=b'9'){}else{invalid("JSON integer syntax is invalid")}
            case 4=>if(byte>=b'0' && byte<=b'9'){number=5}else{invalid("JSON decimal has no fraction")}
            case 5=>if(byte==b'e' || byte==b'E'){number=6}else if(byte>=b'0' && byte<=b'9'){}else{invalid("JSON fraction syntax is invalid")}
            case 6=>if(byte==b'+' || byte==b'-'){number=7}else if(byte>=b'0' && byte<=b'9'){number=8}else{invalid("JSON exponent syntax is invalid")}
            case 7 | 8=>if(byte>=b'0' && byte<=b'9'){number=8}else{invalid("JSON exponent has no digits")}
            case _=>invalid("JSON number state is invalid")}
        ascii(byte)
    }
    private func tokenDone():Unit{
        if(mode==2 && ![2,3,5,8].contains(number)){invalid("JSON number is incomplete")}
        if(mode==3 && literalOffset!=literal.size){invalid("JSON literal is incomplete")};scalarDone()
    }
    private func delimiter(byte:Byte):Bool{
        byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n' || byte==b',' || byte==b']' || byte==b'}'
    }
    private func syntax(byte:Byte):Unit{
        if(byte==b' ' || byte==b'\t' || byte==b'\r' || byte==b'\n'){return}
        if(byte==b'"'){beginString();return}
        if(byte==b'{' || byte==b'['){
            let location=begin(if(byte==b'{'){"object"}else{"array"})
            if(frames.size>=32){invalid("JSON exceeds original depth32")}
            for(index in selectedComparisons){comparisons[index].finish()}
            selected=[];selectedComparisons=[]
            frames.add(LiveProposalFrame296(byte==b'{',location.depth,location.matches,location.comparisons,selectedPath296,position296))
            selectedPath296=[];selectedKind296="";return
        }
        if(byte==b'}' || byte==b']'){
            if(frames.isEmpty() || top().object!=(byte==b'}') ||
                (top().object && top().phase!=0 && top().phase!=3) ||
                (!top().object && top().phase!=0 && top().phase!=1)){invalid("JSON container is incomplete")}
            let retired=frames.remove(at:frames.size-1)
            endValue(retired.path296,if(retired.object){"object"}else{"array"},retired.start296,position296+1)
            keyBytesRetained-=retired.keyBytes;keysRetained-=retired.keys.size
            if(frames.isEmpty()){root=2};return
        }
        if(byte==b':'){
            if(frames.isEmpty() || !top().object || top().phase!=1){invalid("JSON object key lacks its colon")}
            top().phase=2;return
        }
        if(byte==b','){
            if(frames.isEmpty() || (top().object && top().phase!=3) || (!top().object && top().phase!=1)){invalid("JSON comma is outside a completed value")}
            top().phase=if(top().object){4}else{2};return
        }
        if(byte==b'-' || (byte>=b'0' && byte<=b'9')){let _=begin("number");mode=2;number=0;numberByte(byte);return}
        if(byte==b't' || byte==b'f' || byte==b'n'){
            let _=begin(if(byte==b'n'){"null"}else{"boolean"})
            mode=3;literal=if(byte==b't'){"true"}else if(byte==b'f'){"false"}else{"null"};literalOffset=1;return
        }
        invalid("JSON value has an invalid first byte")
    }
    func append(expectedOffset:Int64,bytes:Array<Byte>):Unit{
        if(complete || expectedOffset!=offset || bytes.isEmpty() || bytes.size>65536 || bytes.size>expectedBytes-offset){
            invalid("JSON structural stream skips, overlaps or exceeds its exact extent")}
        charge(bytes.size+128);hash.write(bytes)
        for(byte in bytes){
            if(mode==1){stringByte(byte)}
            else if(mode==2 || mode==3){
                if(delimiter(byte)){tokenDone();syntax(byte)}
                else if(mode==2){numberByte(byte)}
                else{if(literalOffset>=literal.size || literal[literalOffset]!=byte){invalid("JSON literal syntax is invalid")};literalOffset++}
            }else{syntax(byte)}
            position296++
        };offset+=bytes.size
    }
    func finish():LiveProposalProjection296{
        if(complete || offset!=expectedBytes || mode==1){invalid("JSON structural stream is incomplete")}
        if(mode==2 || mode==3){tokenDone()}
        if(root!=2 || !frames.isEmpty()){invalid("JSON structural containers are incomplete")}
        let digest=logicalJsonEncodeHex(hash.finish());if(digest!=expectedDigest){invalid("JSON structural stream changed from its complete observed digest")}
        charge(65536)
        let value=objectValue([ValueField("schema",textValue(projectedSchema)),
            ValueField("fields",listValue(Array<AgentValue>(publicFields,{index=>fields[index].value()})))])
        complete=true;LiveProposalProjection296(value,comparisons.map{comparison=>comparison.seen && comparison.matches})
    }
}
