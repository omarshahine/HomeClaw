import Foundation

/// Canonical MCP tool registration shared by native HTTP and stdio clients.
/// HTTP applies an explicit read-only allowlist; stdio retains the full tool set.
enum ToolHandlers {
    static let allToolsJSON: Data = {
        let encoded = """
W3sibmFtZSI6ImhvbWVraXRfc3RhdHVzIiwiZGVzY3JpcHRpb24iOiJDaGVjayBIb21lQ2xhdyBzdGF0dXMg4oCUIHNob3dzIGNv
bm5lY3Rpdml0eSwgaG9tZSBjb3VudCwgYW5kIGFjY2Vzc29yeSBjb3VudC4iLCJpbnB1dFNjaGVtYSI6eyJ0eXBlIjoib2JqZWN0
IiwicHJvcGVydGllcyI6e319fSx7Im5hbWUiOiJob21la2l0X2FjY2Vzc29yaWVzIiwiZGVzY3JpcHRpb24iOiJNYW5hZ2UgSG9t
ZUtpdCBhY2Nlc3NvcmllczogbGlzdCBhbGwsIGdldCBkZXRhaWxzLCBzZWFyY2ggYnkgbmFtZS9yb29tL2NhdGVnb3J5LCBvciBj
b250cm9sIChzZXQgY2hhcmFjdGVyaXN0aWMgdmFsdWVzKS4gUmV0dXJucyBvbmx5IGFjY2Vzc29yaWVzIHZpc2libGUgdW5kZXIg
dGhlIGN1cnJlbnQgZmlsdGVyIGNvbmZpZ3VyYXRpb24uIERlZmF1bHRzIHRvIGNvbmZpZ3VyZWQgaG9tZSBpZiBob21lX2lkIG5v
dCBzcGVjaWZpZWQuIiwiaW5wdXRTY2hlbWEiOnsidHlwZSI6Im9iamVjdCIsInByb3BlcnRpZXMiOnsiYWN0aW9uIjp7InR5cGUi
OiJzdHJpbmciLCJlbnVtIjpbImxpc3QiLCJnZXQiLCJzZWFyY2giLCJjb250cm9sIl0sImRlc2NyaXB0aW9uIjoiQWN0aW9uIHRv
IHBlcmZvcm0uIERlZmF1bHQ6IGxpc3QifSwiaG9tZV9pZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJGaWx0ZXIg
YnkgaG9tZSBVVUlELiBEZWZhdWx0cyB0byBjb25maWd1cmVkIGhvbWUgaWYgbm90IHNwZWNpZmllZC4ifSwicm9vbSI6eyJ0eXBl
Ijoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJGaWx0ZXIgYnkgcm9vbSBuYW1lIChsaXN0IGFjdGlvbiBvbmx5KSJ9LCJhY2Nlc3Nv
cnlfaWQiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiQWNjZXNzb3J5IFVVSUQgb3IgbmFtZSAoZ2V0L2NvbnRyb2wg
YWN0aW9ucykifSwicXVlcnkiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiU2VhcmNoIHF1ZXJ5IOKAlCBtYXRjaGVz
IG5hbWUsIHJvb20sIGNhdGVnb3J5IChzZWFyY2ggYWN0aW9uKSJ9LCJjYXRlZ29yeSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3Jp
cHRpb24iOiJGaWx0ZXIgYnkgY2F0ZWdvcnkgZS5nLiBsaWdodGJ1bGIsIGxvY2ssIHRoZXJtb3N0YXQgKHNlYXJjaCBhY3Rpb24p
In0sImNoYXJhY3RlcmlzdGljIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IkNoYXJhY3RlcmlzdGljIHRvIHNldCBl
LmcuIHBvd2VyLCBicmlnaHRuZXNzLCB0YXJnZXRfdGVtcGVyYXR1cmUgKGNvbnRyb2wgYWN0aW9uKSJ9LCJ2YWx1ZSI6eyJ0eXBl
Ijoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJWYWx1ZSB0byBzZXQgZS5nLiB0cnVlLCA3NSwgbG9ja2VkIChjb250cm9sIGFjdGlv
bikifSwic2VydmljZV90eXBlIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IlNlcnZpY2UgVFlQRSBVVUlEIHRvIG5h
cnJvdyB0aGUgdGFyZ2V0IHdoZW4gdGhlIGNoYXJhY3RlcmlzdGljIGV4aXN0cyBvbiBtdWx0aXBsZSBzZXJ2aWNlcyAoY29udHJv
bCBhY3Rpb24pLiBOb3RlOiBldmVyeSBjaGFubmVsIG9mIGEgbXVsdGktZ2FuZyBzd2l0Y2ggc2hhcmVzIG9uZSBzZXJ2aWNlIHR5
cGUsIHNvIHRoaXMgYWxvbmUgY2Fubm90IHBpY2sgYSBjaGFubmVsIOKAlCB1c2Ugc2VydmljZV9uYW1lIG9yIHNlcnZpY2VfaW5k
ZXggZm9yIHRoYXQuIn0sInNlcnZpY2VfbmFtZSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJOYW1lIG9yIHVuaXF1
ZSBVVUlEIG9mIHRoZSBzcGVjaWZpYyBzZXJ2aWNlIHRvIHdyaXRlIHRvIChjb250cm9sIGFjdGlvbikuIFRoaXMgaXMgaG93IHlv
dSBwaWNrIG9uZSBjaGFubmVsIG9mIGEgbXVsdGktZ2FuZyBzd2l0Y2guIEJvdGggdmFsdWVzIGFyZSBsaXN0ZWQgaW4gdGhlIGFt
YmlndWl0eSBlcnJvciBhbmQgaW4gdGhlIGdldCBhY3Rpb24gb3V0cHV0LiJ9LCJzZXJ2aWNlX2lkIjp7InR5cGUiOiJzdHJpbmci
LCJkZXNjcmlwdGlvbiI6IlVuaXF1ZSBVVUlEIG9mIHRoZSBzcGVjaWZpYyBzZXJ2aWNlIHRvIHdyaXRlIHRvIChjb250cm9sIGFj
dGlvbikuIExpc3RlZCBhcyBgc2VydmljZV9pZGAgaW4gdGhlIGFtYmlndWl0eSBlcnJvciBhbmQgYXMgYGlkYCBwZXIgc2Vydmlj
ZSBpbiB0aGUgZ2V0IGFjdGlvbiBvdXRwdXQuIFVzZSB0aGlzIHdoZW4gdHdvIHNlcnZpY2VzIHNoYXJlIGEgbmFtZS4ifSwic2Vy
dmljZV9pbmRleCI6eyJ0eXBlIjoibnVtYmVyIiwiZGVzY3JpcHRpb24iOiJDaGFubmVsIG51bWJlciAoU2VydmljZUxhYmVsSW5k
ZXgpIG9mIHRoZSBzcGVjaWZpYyBzZXJ2aWNlIHRvIHdyaXRlIHRvLCBlLmcuIDEgZm9yIHRoZSBmaXJzdCBnYW5nIChjb250cm9s
IGFjdGlvbikuIExpc3RlZCBhcyBgaW5kZXhgIGluIHRoZSBnZXQgYWN0aW9uIG91dHB1dCB3aGVuIHRoZSBhY2Nlc3NvcnkgcmVw
b3J0cyBvbmUuIn0sInZlcmlmeSI6eyJ0eXBlIjoiYm9vbGVhbiIsImRlc2NyaXB0aW9uIjoiRGVmYXVsdCB0cnVlIChjb250cm9s
IGFjdGlvbikuIEFmdGVyIHdyaXRpbmcsIHRoZSB2YWx1ZSBpcyByZWFkIGJhY2sgYW5kIGEgd3JpdGUgdGhlIGRldmljZSBkaWQg
bm90IGFwcGx5IGlzIHJldHVybmVkIGFzIGFuIGVycm9yIHJhdGhlciB0aGFuIGEgc3VjY2Vzcy4gU2V0IGZhbHNlIG9ubHkgZm9y
IGFjY2Vzc29yaWVzIHdob3NlIHJlYWRiYWNrIGlzIHVucmVsaWFibGU7IHRoZSByZXNwb25zZSB0aGVuIGNhcnJpZXMgdmVyaWZp
Y2F0aW9uX3NraXBwZWQ6IFwiZGlzYWJsZWRcIi4ifSwibm9fcmVmcmVzaCI6eyJ0eXBlIjoiYm9vbGVhbiIsImRlc2NyaXB0aW9u
IjoiU2tpcCBsaXZlIGNoYXJhY3RlcmlzdGljIHJlYWRzIGFuZCByZXR1cm4gbGFzdC1rbm93biArIHN0YXRpYyB2YWx1ZXMgb25s
eSAoZ2V0IGFjdGlvbikuIE11Y2ggZmFzdGVyIGFuZCBhdm9pZHMgcGVyLWNhbGwgc2xvd2Rvd25zIHdoZW4gcmVhZGluZyBtYW55
IGFjY2Vzc29yaWVzIGluIHNlcXVlbmNlOyBzYWZlIGZvciBzdGF0aWMgbWV0YWRhdGEgbGlrZSBzZXJpYWwgbnVtYmVyLCBtb2Rl
bCwgYW5kIGZpcm13YXJlLiJ9fX19LHsibmFtZSI6ImhvbWVraXRfcm9vbXMiLCJkZXNjcmlwdGlvbiI6Ikxpc3QgSG9tZUtpdCBy
b29tcyBhbmQgdGhlaXIgYWNjZXNzb3JpZXMuIERlZmF1bHRzIHRvIGNvbmZpZ3VyZWQgaG9tZSBpZiBob21lX2lkIG5vdCBzcGVj
aWZpZWQuIiwiaW5wdXRTY2hlbWEiOnsidHlwZSI6Im9iamVjdCIsInByb3BlcnRpZXMiOnsiaG9tZV9pZCI6eyJ0eXBlIjoic3Ry
aW5nIiwiZGVzY3JpcHRpb24iOiJGaWx0ZXIgYnkgaG9tZSBVVUlELiBEZWZhdWx0cyB0byBjb25maWd1cmVkIGhvbWUgaWYgbm90
IHNwZWNpZmllZC4ifX19fSx7Im5hbWUiOiJob21la2l0X3NjZW5lcyIsImRlc2NyaXB0aW9uIjoiTGlzdCwgZ2V0IGRldGFpbHMg
b2YsIG9yIHRyaWdnZXIgSG9tZUtpdCBzY2VuZXMgKGFjdGlvbiBzZXRzKS4gRGVmYXVsdHMgdG8gY29uZmlndXJlZCBob21lIGlm
IGhvbWVfaWQgbm90IHNwZWNpZmllZC4iLCJpbnB1dFNjaGVtYSI6eyJ0eXBlIjoib2JqZWN0IiwicHJvcGVydGllcyI6eyJhY3Rp
b24iOnsidHlwZSI6InN0cmluZyIsImVudW0iOlsibGlzdCIsImdldCIsInRyaWdnZXIiXSwiZGVzY3JpcHRpb24iOiJBY3Rpb24g
dG8gcGVyZm9ybS4gRGVmYXVsdDogbGlzdC4gXCJnZXRcIiByZXR1cm5zIGFsbCBhY3Rpb25zIGluIHRoZSBzY2VuZS4ifSwiaG9t
ZV9pZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJGaWx0ZXIgYnkgaG9tZSBVVUlEIChsaXN0L2dldCBhY3Rpb24p
LiBEZWZhdWx0cyB0byBjb25maWd1cmVkIGhvbWUgaWYgbm90IHNwZWNpZmllZC4ifSwic2NlbmVfaWQiOnsidHlwZSI6InN0cmlu
ZyIsImRlc2NyaXB0aW9uIjoiU2NlbmUgVVVJRCBvciBuYW1lIChnZXQvdHJpZ2dlciBhY3Rpb24pIn19fX0seyJuYW1lIjoiaG9t
ZWtpdF9kZXZpY2VfbWFwIiwiZGVzY3JpcHRpb24iOiJHZXQgYW4gTExNLW9wdGltaXplZCBkZXZpY2UgbWFwIG9yZ2FuaXplZCBi
eSBob21lL3pvbmUvcm9vbSB3aXRoIHNlbWFudGljIHR5cGVzLCBhdXRvLWdlbmVyYXRlZCBhbGlhc2VzLCBjb250cm9sbGFibGUg
Y2hhcmFjdGVyaXN0aWNzLCBhbmQgc3RhdGUgc3VtbWFyaWVzLiBVc2UgdGhpcyB0byB1bmRlcnN0YW5kIHRoZSBmdWxsIGRldmlj
ZSBsYW5kc2NhcGUgYmVmb3JlIGNvbnRyb2xsaW5nIGRldmljZXMuIiwiaW5wdXRTY2hlbWEiOnsidHlwZSI6Im9iamVjdCIsInBy
b3BlcnRpZXMiOnsiaG9tZV9pZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJGaWx0ZXIgYnkgaG9tZSBVVUlELiBE
ZWZhdWx0cyB0byBjb25maWd1cmVkIGhvbWUgaWYgbm90IHNwZWNpZmllZC4ifX19fSx7Im5hbWUiOiJob21la2l0X21hbmFnZSIs
ImRlc2NyaXB0aW9uIjoiTWFuYWdlIEhvbWVLaXQgc3RydWN0dXJlOiByZW5hbWUgYWNjZXNzb3JpZXMsIGFzc2lnbiByb29tcyAo
d2l0aCBVVUlEIHN1cHBvcnQgZm9yIGR1cGxpY2F0ZSBuYW1lcyksIGNyZWF0ZS9yZW5hbWUvcmVtb3ZlIHJvb21zLCByZW1vdmUg
YWNjZXNzb3JpZXMsIGNyZWF0ZS9yZW1vdmUgem9uZXMsIGFuZCBtYW5hZ2Ugem9uZSBtZW1iZXJzaGlwLiBBbGwgYWN0aW9ucyBz
dXBwb3J0IGRyeV9ydW4gZm9yIHNhZmUgcHJldmlld3MuIiwiaW5wdXRTY2hlbWEiOnsidHlwZSI6Im9iamVjdCIsInByb3BlcnRp
ZXMiOnsiYWN0aW9uIjp7InR5cGUiOiJzdHJpbmciLCJlbnVtIjpbInJlbmFtZSIsInJlbW92ZV9hY2Nlc3NvcnkiLCJhc3NpZ25f
cm9vbXMiLCJjcmVhdGVfcm9vbSIsInJlbmFtZV9yb29tIiwicmVtb3ZlX3Jvb20iLCJjcmVhdGVfem9uZSIsInJlbW92ZV96b25l
IiwiYWRkX3Jvb21fdG9fem9uZSIsInJlbW92ZV9yb29tX2Zyb21fem9uZSJdLCJkZXNjcmlwdGlvbiI6Ik1hbmFnZW1lbnQgYWN0
aW9uIHRvIHBlcmZvcm0ifSwiaG9tZV9pZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJIb21lIFVVSUQgb3IgbmFt
ZS4gRGVmYXVsdHMgdG8gY29uZmlndXJlZCBob21lLiJ9LCJpZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJBY2Nl
c3NvcnksIHJvb20sIG9yIHpvbmUgbmFtZS9VVUlEIChhY3Rpb24tZGVwZW5kZW50KSJ9LCJuZXdfbmFtZSI6eyJ0eXBlIjoic3Ry
aW5nIiwiZGVzY3JpcHRpb24iOiJOZXcgbmFtZSBmb3IgcmVuYW1lIGFjdGlvbnMifSwibmFtZSI6eyJ0eXBlIjoic3RyaW5nIiwi
ZGVzY3JpcHRpb24iOiJOYW1lIGZvciBjcmVhdGUgYWN0aW9ucyAoY3JlYXRlX3Jvb20sIGNyZWF0ZV96b25lKSJ9LCJyb29tIjp7
InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IlJvb20gbmFtZS9VVUlEICh6b25lIG1lbWJlcnNoaXAgYWN0aW9ucykifSwi
em9uZSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJab25lIG5hbWUvVVVJRCAoem9uZSBtZW1iZXJzaGlwIGFjdGlv
bnMpIn0sImFzc2lnbm1lbnRzIjp7InR5cGUiOiJhcnJheSIsIml0ZW1zIjp7InR5cGUiOiJvYmplY3QiLCJwcm9wZXJ0aWVzIjp7
InV1aWQiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiQWNjZXNzb3J5IFVVSUQgKHByZWZlcnJlZCBmb3IgZHVwbGlj
YXRlIG5hbWVzKSJ9LCJhY2Nlc3NvcnkiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiQWNjZXNzb3J5IG5hbWUgKGZh
bGxiYWNrLCBjYXNlLWluc2Vuc2l0aXZlKSJ9LCJyb29tIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IlRhcmdldCBy
b29tIG5hbWUgKGNyZWF0ZWQgaWYgbWlzc2luZykifX0sInJlcXVpcmVkIjpbInJvb20iXX0sImRlc2NyaXB0aW9uIjoiQXJyYXkg
b2Ygcm9vbSBhc3NpZ25tZW50cyAoYXNzaWduX3Jvb21zIGFjdGlvbikuIEVhY2ggbXVzdCBoYXZlIFwicm9vbVwiIHBsdXMgZWl0
aGVyIFwidXVpZFwiIG9yIFwiYWNjZXNzb3J5XCIuIn0sImRyeV9ydW4iOnsidHlwZSI6ImJvb2xlYW4iLCJkZXNjcmlwdGlvbiI6
IlByZXZpZXcgY2hhbmdlcyB3aXRob3V0IGFwcGx5aW5nIChkZWZhdWx0OiBmYWxzZSkifX0sInJlcXVpcmVkIjpbImFjdGlvbiJd
fX0seyJuYW1lIjoiaG9tZWtpdF9jb25maWciLCJkZXNjcmlwdGlvbiI6IlZpZXcgb3IgdXBkYXRlIEhvbWVDbGF3IGNvbmZpZ3Vy
YXRpb24uIFNldCBhIGRlZmF1bHQgaG9tZSwgb3IgY29uZmlndXJlIGRldmljZSBmaWx0ZXJpbmcgdG8gY29udHJvbCB3aGljaCBh
Y2Nlc3NvcmllcyBhcmUgZXhwb3NlZC4iLCJpbnB1dFNjaGVtYSI6eyJ0eXBlIjoib2JqZWN0IiwicHJvcGVydGllcyI6eyJhY3Rp
b24iOnsidHlwZSI6InN0cmluZyIsImVudW0iOlsiZ2V0Iiwic2V0Il0sImRlc2NyaXB0aW9uIjoiQWN0aW9uIHRvIHBlcmZvcm0u
IERlZmF1bHQ6IGdldCJ9LCJkZWZhdWx0X2hvbWVfaWQiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiSG9tZSBVVUlE
IG9yIG5hbWUgdG8gc2V0IGFzIGFjdGl2ZSBob21lIChzZXQgYWN0aW9uKS4gQWxsIGNvbW1hbmRzIG9wZXJhdGUgb24gdGhlIGFj
dGl2ZSBob21lLiJ9LCJhY2Nlc3NvcnlfZmlsdGVyX21vZGUiOnsidHlwZSI6InN0cmluZyIsImVudW0iOlsiYWxsIiwiYWxsb3ds
aXN0Il0sImRlc2NyaXB0aW9uIjoiRmlsdGVyIG1vZGU6IFwiYWxsXCIgZXhwb3NlcyBldmVyeSBhY2Nlc3NvcnksIFwiYWxsb3ds
aXN0XCIgb25seSBleHBvc2VzIHNlbGVjdGVkIGFjY2Vzc29yaWVzIChzZXQgYWN0aW9uKS4ifSwiYWxsb3dlZF9hY2Nlc3Nvcnlf
aWRzIjp7InR5cGUiOiJhcnJheSIsIml0ZW1zIjp7InR5cGUiOiJzdHJpbmcifSwiZGVzY3JpcHRpb24iOiJBcnJheSBvZiBhY2Nl
c3NvcnkgVVVJRHMgdG8gZXhwb3NlIHdoZW4gZmlsdGVyIG1vZGUgaXMgXCJhbGxvd2xpc3RcIiAoc2V0IGFjdGlvbikuIn19fX0s
eyJuYW1lIjoiaG9tZWtpdF9hdXRvbWF0aW9ucyIsImRlc2NyaXB0aW9uIjoiTWFuYWdlIEhvbWVLaXQgYXV0b21hdGlvbnMuIExp
c3QgZXhpc3RpbmcgYXV0b21hdGlvbnMsIGluc3BlY3QgdGhlaXIgZXZlbnRzIGFuZCBsaW5rZWQgc2NlbmVzLCBjcmVhdGUgYXV0
b21hdGlvbnMgdHJpZ2dlcmVkIGJ5IGFueSBjaGFyYWN0ZXJpc3RpYyBjaGFuZ2UgKGJ1dHRvbiBwcmVzc2VzLCBtb3Rpb24gc2Vu
c29ycywgY29udGFjdCBzZW5zb3JzLCBvY2N1cGFuY3ksIGV0Yy4pIG9yIGJ5IGEgdGltZSBvZiBkYXkgKGNsb2NrIG9yIHN1bnJp
c2Uvc3Vuc2V0KSwgZGVsZXRlIGF1dG9tYXRpb25zLCBvciBlbmFibGUvZGlzYWJsZSB0aGVtLiBGb3IgY2hhcmFjdGVyaXN0aWMt
Y2hhbmdlIHRyaWdnZXJzIHVzZSBhY3Rpb249Y3JlYXRlIHdpdGggcHJlc3NfdHlwZSAoYnV0dG9ucykgb3IgY2hhcmFjdGVyaXN0
aWMrdHJpZ2dlcl92YWx1ZSAoc2Vuc29ycykuIEZvciB0aW1lLW9mLWRheSB0cmlnZ2VycyB1c2UgYWN0aW9uPWNyZWF0ZV90aW1l
IHdpdGggdGhlIGB0aW1lYCBmaWVsZCAoSEg6TU0sIHN1bnJpc2UsIHN1bnNldCwgb3IgPHN1bi1ldmVudD7CsU4pLiBCb3RoIGNy
ZWF0ZSBhY3Rpb25zIGFjY2VwdCB0aGUgc2FtZSBwcmVkaWNhdGUgdm9jYWJ1bGFyeTogd2Vla2RheXMsIGNvbmRpdGlvbnMsIHRp
bWVfYWZ0ZXIsIHRpbWVfYmVmb3JlLCBkdXJhdGlvbl9zZWNvbmRzLiBVc2UgZHVyYXRpb25fc2Vjb25kcyB0byBhdXRvLXJldmVy
dCBhY3Rpb25zIGFmdGVyIE4gc2Vjb25kcyAoZS5nLiBtb3Rpb24tdHJpZ2dlcmVkIGxpZ2h0cyBvciBzdW5zZXQgcG9yY2ggbGln
aHRzIHRoYXQgdHVybiBvZmYgYWZ0ZXIgYSBkZWxheSkuIFVzZSBhY3Rpb249YWRkX2NvbmRpdGlvbiB0byBhcHBlbmQgYSBjaGFy
YWN0ZXJpc3RpYyBjb25kaXRpb24gKEFORGVkKSB0byBhbiBleGlzdGluZyBhdXRvbWF0aW9uIGluIHBsYWNlIOKAlCB0aGUgdHJp
Z2dlciBVVUlEIGlzIHByZXNlcnZlZCwgc28gYnV0dG9uIGJpbmRpbmdzIGFuZCBTaXJpIHJlZmVyZW5jZXMgc3Vydml2ZS4gTGlz
dC9nZXQgYWxzbyBzdXJmYWNlIEhNVGltZXJUcmlnZ2VyIGF1dG9tYXRpb25zIChBcHBsZSBIb21lIG5hdGl2ZSB0aW1lIGF1dG9t
YXRpb25zKSBhbmQgSE1DYWxlbmRhckV2ZW50IC8gSE1TaWduaWZpY2FudFRpbWVFdmVudCAvIEhNRHVyYXRpb25FdmVudCBkZXRh
aWxzIG9uIGV2ZW50IHRyaWdnZXJzOyByZXN1bHQgcm93cyBpbmNsdWRlIHRyaWdnZXJfdHlwZSAoXCJidXR0b25cIiB8IFwiY2hh
cmFjdGVyaXN0aWNcIiB8IFwiY2FsZW5kYXJcIiB8IFwic2lnbmlmaWNhbnRfdGltZVwiIHwgXCJ0aW1lclwiIHwgXCJ1bmtub3du
XCIpIGFuZCwgd2hlcmUgYXBwbGljYWJsZSwgZmlyZV90aW1lLCBmaXJlX2RhdGUsIGFuZCBkdXJhdGlvbl9zZWNvbmRzLiBEZWxl
dGUvZW5hYmxlL2Rpc2FibGUgYWNjZXB0IGFueSB0cmlnZ2VyIHN1YnR5cGUuIE5vdGU6IHRoZSBwcmVkaWNhdGUtY29tcG9zaXRp
b24gZmVhdHVyZXMgKGNvbmRpdGlvbnMsIHRpbWVfYWZ0ZXIvdGltZV9iZWZvcmUsIGFkZF9jb25kaXRpb24pIGFyZSBidWlsdCBv
biBzdGFuZGFyZCBITUV2ZW50VHJpZ2dlciBwcmVkaWNhdGUgY29tcG9zaXRpb24g4oCUIHN1cHBvcnRlZCBieSBBcHBsZSdzIEhv
bWVLaXQgZnJhbWV3b3JrIEFQSXMgYnV0IG5vdCB5ZXQgc3VyZmFjZWQgaW4gdGhlIEhvbWUgYXBwJ3MgQXV0b21hdGlvbnMgdGFi
LiBUaGV5IG1pcnJvciB0aGUgcnVsZS1lZGl0b3IgY2FwYWJpbGl0aWVzIGV4cG9zZWQgYnkgdGhpcmQtcGFydHkgSG9tZUtpdCBh
cHBzIGxpa2UgQ29udHJvbGxlciBmb3IgSG9tZUtpdC4gUnVsZXMgY3JlYXRlZCBvciBtb2RpZmllZCB0aGlzIHdheSBleGVjdXRl
IGNvcnJlY3RseSB2aWEgSG9tZUtpdDsgdXNlIGxpc3QvZ2V0IHRvIGluc3BlY3QgdGhlbSBzaW5jZSB0aGV5IG1heSBub3QgYmUg
ZWRpdGFibGUgZnJvbSB0aGUgSG9tZSBhcHAuIiwiaW5wdXRTY2hlbWEiOnsidHlwZSI6Im9iamVjdCIsInByb3BlcnRpZXMiOnsi
YWN0aW9uIjp7InR5cGUiOiJzdHJpbmciLCJlbnVtIjpbImxpc3QiLCJnZXQiLCJjcmVhdGUiLCJjcmVhdGVfdGltZSIsImRlbGV0
ZSIsImVuYWJsZSIsImRpc2FibGUiLCJhZGRfY29uZGl0aW9uIl0sImRlc2NyaXB0aW9uIjoiQWN0aW9uIHRvIHBlcmZvcm0uIERl
ZmF1bHQ6IGxpc3QifSwiaG9tZV9pZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJIb21lIFVVSUQgb3IgbmFtZS4g
RGVmYXVsdHMgdG8gY29uZmlndXJlZCBob21lLiJ9LCJpZCI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJBdXRvbWF0
aW9uIFVVSUQgb3IgbmFtZSAoZ2V0L2RlbGV0ZS9lbmFibGUvZGlzYWJsZSBhY3Rpb25zKSJ9LCJuYW1lIjp7InR5cGUiOiJzdHJp
bmciLCJkZXNjcmlwdGlvbiI6IkF1dG9tYXRpb24gbmFtZSAoY3JlYXRlIC8gY3JlYXRlX3RpbWUgYWN0aW9ucykifSwiYWNjZXNz
b3J5X2lkIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IlRyaWdnZXIgYWNjZXNzb3J5IFVVSUQgb3IgbmFtZSAoY3Jl
YXRlIGFjdGlvbikifSwidGltZSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJUaW1lIG9mIGRheSB0aGUgYXV0b21h
dGlvbiBmaXJlcyAoY3JlYXRlX3RpbWUgYWN0aW9uLCByZXF1aXJlZCkuIEZvcm1hdDogXCJISDpNTVwiIGZvciBhIHdhbGwtY2xv
Y2sgdGltZSAoZS5nLiBcIjA2OjMwXCIsIFwiMTc6NDVcIjsgYm90aCBmaWVsZHMgbXVzdCBiZSB6ZXJvLXBhZGRlZCB0d28gZGln
aXRzIOKAlCBcIjY6MzBcIiBpcyByZWplY3RlZCksIFwic3VucmlzZVwiL1wic3Vuc2V0XCIgZm9yIHN1bi1yZWxhdGl2ZSBldmVu
dHMsIG9yIFwiPHN1bi1ldmVudD7CsU5cIiB3aGVyZSBOIGlzIG1pbnV0ZXMgKGUuZy4gXCJzdW5zZXQtMzBcIiwgXCJzdW5yaXNl
KzE1XCIpLiBPZmZzZXRzIGxhcmdlciB0aGFuIDE0NDAgbWludXRlcyAoMjRoKSBhcmUgcmVqZWN0ZWQuIEltcGxlbWVudGVkIGFz
IEhNQ2FsZW5kYXJFdmVudCBmb3IgSEg6TU0gYW5kIEhNU2lnbmlmaWNhbnRUaW1lRXZlbnQgZm9yIHN1bnJpc2Uvc3Vuc2V0LiBB
bGwgb3RoZXIgcHJlZGljYXRlIGZsYWdzICh3ZWVrZGF5cywgY29uZGl0aW9ucywgdGltZV9hZnRlciwgdGltZV9iZWZvcmUsIGR1
cmF0aW9uX3NlY29uZHMpIGNvbXBvc2Ugd2l0aCBgdGltZWAgdGhlIHNhbWUgd2F5IHRoZXkgZG8gb24gdGhlIGNyZWF0ZSBhY3Rp
b24g4oCUIGB0aW1lYCBpcyB0aGUgdHJpZ2dlciBldmVudCwgdGhvc2UgYXJlIHRoZSBnYXRpbmcgcHJlZGljYXRlcy4ifSwic2Nl
bmVfaWQiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiU2NlbmUgVVVJRCBvciBuYW1lIHRvIHRyaWdnZXIgKGNyZWF0
ZSAvIGNyZWF0ZV90aW1lIGFjdGlvbnMpLiBBbHRlcm5hdGl2ZSB0byBhY3Rpb25zLiJ9LCJhY3Rpb25zIjp7InR5cGUiOiJhcnJh
eSIsIml0ZW1zIjp7InR5cGUiOiJvYmplY3QiLCJwcm9wZXJ0aWVzIjp7ImFjY2Vzc29yeSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVz
Y3JpcHRpb24iOiJUYXJnZXQgYWNjZXNzb3J5IFVVSUQgKHN0cm9uZ2x5IHByZWZlcnJlZCkgb3IgbmFtZSJ9LCJwcm9wZXJ0eSI6
eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJDaGFyYWN0ZXJpc3RpYyB0byBzZXQgKGUuZy4sIHBvd2VyLCBicmlnaHRu
ZXNzLCBjb2xvcl90ZW1wZXJhdHVyZSkifSwiY2hhcmFjdGVyaXN0aWMiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoi
QWxpYXMgZm9yIFwicHJvcGVydHlcIiDigJQgcHJvdmlkZSBvbmUgb3IgdGhlIG90aGVyIn0sInZhbHVlIjp7InR5cGUiOiJzdHJp
bmciLCJkZXNjcmlwdGlvbiI6IlRhcmdldCB2YWx1ZSBhcyBzdHJpbmcgKGUuZy4sIFwidHJ1ZVwiLCBcIjUwXCIsIFwiMzQ0XCIp
In0sInJvb20iOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiUm9vbSBuYW1lIGZvciBkaXNhbWJpZ3VhdGlvbiAob3B0
aW9uYWwpIn19LCJyZXF1aXJlZCI6WyJhY2Nlc3NvcnkiLCJ2YWx1ZSJdLCJhbnlPZiI6W3sicmVxdWlyZWQiOlsicHJvcGVydHki
XX0seyJyZXF1aXJlZCI6WyJjaGFyYWN0ZXJpc3RpYyJdfV19LCJkZXNjcmlwdGlvbiI6IklubGluZSBhY3Rpb25zIGZvciB0aGUg
YXV0b21hdGlvbiAoY3JlYXRlIC8gY3JlYXRlX3RpbWUgYWN0aW9ucykuIEFsdGVybmF0aXZlIHRvIHNjZW5lX2lkLiBDcmVhdGVz
IGEgc2NlbmUgbmFtZWQgYWZ0ZXIgdGhlIGF1dG9tYXRpb24uIEVhY2ggYWN0aW9uIHNldHMgb25lIGNoYXJhY3RlcmlzdGljIG9u
IG9uZSBhY2Nlc3NvcnkuIn0sInByZXNzX3R5cGUiOnsidHlwZSI6Im51bWJlciIsImVudW0iOlswLDEsMl0sImRlc2NyaXB0aW9u
IjoiQnV0dG9uIHByZXNzIHR5cGU6IDA9c2luZ2xlIChkZWZhdWx0KSwgMT1kb3VibGUsIDI9bG9uZyBwcmVzcy4gRm9yIGJ1dHRv
biB0cmlnZ2VycyBvbmx5OyBtdXR1YWxseSBleGNsdXNpdmUgd2l0aCBjaGFyYWN0ZXJpc3RpYy4gKGNyZWF0ZSBhY3Rpb24pIn0s
ImNoYXJhY3RlcmlzdGljIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IkNoYXJhY3RlcmlzdGljIG5hbWUgdG8gdHJp
Z2dlciBvbiAoZS5nLiwgbW90aW9uX2RldGVjdGVkLCBjb250YWN0X3N0YXRlLCBvY2N1cGFuY3lfZGV0ZWN0ZWQsIGN1cnJlbnRf
dGVtcGVyYXR1cmUpLiBBbHRlcm5hdGl2ZSB0byBwcmVzc190eXBlIGZvciBub24tYnV0dG9uIHRyaWdnZXJzLiAoY3JlYXRlIGFj
dGlvbikifSwidHJpZ2dlcl92YWx1ZSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJWYWx1ZSB0aGF0IHRyaWdnZXJz
IHRoZSBhdXRvbWF0aW9uIChlLmcuLCBcInRydWVcIiwgXCJmYWxzZVwiLCBcIjFcIiwgXCIwXCIpLiBSZXF1aXJlZCB3aGVuIGNo
YXJhY3RlcmlzdGljIGlzIHNldC4gVXNlcyBleGFjdCB2YWx1ZSBtYXRjaGluZy4gKGNyZWF0ZSBhY3Rpb24pIn0sInNlcnZpY2Vf
aW5kZXgiOnsidHlwZSI6Im51bWJlciIsImRlc2NyaXB0aW9uIjoiQnV0dG9uIGluZGV4IGZvciBtdWx0aS1idXR0b24gYWNjZXNz
b3JpZXMgKDEgb3IgMikuIEZvciBidXR0b24gdHJpZ2dlcnMgb25seS4gKGNyZWF0ZSBhY3Rpb24pIn0sIndlZWtkYXlzIjp7InR5
cGUiOiJhcnJheSIsIml0ZW1zIjp7InR5cGUiOiJudW1iZXIiLCJlbnVtIjpbMSwyLDMsNCw1LDYsN119LCJkZXNjcmlwdGlvbiI6
IlJlc3RyaWN0IHRoZSBhdXRvbWF0aW9uIHRvIGZpcmUgb25seSBvbiB0aGVzZSB3ZWVrZGF5cyAoMT1TdW4sIDI9TW9uLCAuLi4s
IDc9U2F0KS4gV2hlbiBvbWl0dGVkLCBjaGFyYWN0ZXJpc3RpYy10cmlnZ2VyIGF1dG9tYXRpb25zIChjcmVhdGUpIGZpcmUgZXZl
cnkgZGF5OyB0aW1lLW9mLWRheSBhdXRvbWF0aW9ucyAoY3JlYXRlX3RpbWUpIGF1dG8tZmlsbCBhbGwgNyBkYXlzIHNpbmNlIGlP
UyAxNSsgbWFya3MgdGltZS1jb25kaXRpb25hbCBhdXRvbWF0aW9ucyB3aXRob3V0IHdlZWtkYXkgZ2F0aW5nIGFzIFwidW5yZWxp
YWJsZVwiLiBTZXR0aW5nIHRpbWVfYWZ0ZXIvdGltZV9iZWZvcmUgb24gY3JlYXRlIHdpdGggbm8gd2Vla2RheXMgYWxzbyBhdXRv
LWZpbGxzIGFsbCA3IGRheXMgYW5kIHNldHMgYHdlZWtkYXlzX2F1dG9fZmlsbGVkOiB0cnVlYCBpbiB0aGUgcmVzcG9uc2UuIChj
cmVhdGUgLyBjcmVhdGVfdGltZSBhY3Rpb25zKSJ9LCJjb25kaXRpb25zIjp7InR5cGUiOiJhcnJheSIsIml0ZW1zIjp7InR5cGUi
OiJvYmplY3QiLCJwcm9wZXJ0aWVzIjp7ImFjY2Vzc29yeSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJDb25kaXRp
b24gYWNjZXNzb3J5IFVVSUQgKHByZWZlcnJlZCkgb3IgbmFtZSJ9LCJwcm9wZXJ0eSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3Jp
cHRpb24iOiJDaGFyYWN0ZXJpc3RpYyBuYW1lIChlLmcuLCBjb250YWN0X3N0YXRlLCBvY2N1cGFuY3lfZGV0ZWN0ZWQsIHBvd2Vy
KSJ9LCJjaGFyYWN0ZXJpc3RpYyI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJBbGlhcyBmb3IgXCJwcm9wZXJ0eVwi
IOKAlCBwcm92aWRlIG9uZSBvciB0aGUgb3RoZXIifSwidmFsdWUiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiUmVx
dWlyZWQgdmFsdWUgYXMgc3RyaW5nIChlLmcuLCBcInRydWVcIiwgXCIwXCIsIFwiNTBcIikuIFVzZXMgZXhhY3QgbWF0Y2ggKD09
KS4ifSwicm9vbSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJSb29tIG5hbWUgZm9yIGFjY2Vzc29yeSBkaXNhbWJp
Z3VhdGlvbiB3aGVuIG11bHRpcGxlIGFjY2Vzc29yaWVzIHNoYXJlIGEgbmFtZSAob3B0aW9uYWwpIn19LCJyZXF1aXJlZCI6WyJh
Y2Nlc3NvcnkiLCJ2YWx1ZSJdLCJhbnlPZiI6W3sicmVxdWlyZWQiOlsicHJvcGVydHkiXX0seyJyZXF1aXJlZCI6WyJjaGFyYWN0
ZXJpc3RpYyJdfV19LCJkZXNjcmlwdGlvbiI6IkV4dHJhIGNoYXJhY3RlcmlzdGljIHByZWRpY2F0ZXMgQU5EZWQgaW50byB0aGUg
dHJpZ2dlciBwcmVkaWNhdGUuIFRoZSB0cmlnZ2VyIGZpcmVzIG9ubHkgd2hlbiB0aGUgdHJpZ2dlciBldmVudCBoYXBwZW5zIEFO
RCBldmVyeSBjb25kaXRpb24gaG9sZHMuIEV4YW1wbGU6IHBvcmNoIG1vdGlvbiAob3Igc3Vuc2V0LCBvbiBjcmVhdGVfdGltZSkg
dGhhdCBvbmx5IHRyaWdnZXJzIHdoZW4gdGhlIGZyb250IGRvb3IgaXMgY2xvc2VkIEFORCBub2JvZHkgaXMgaG9tZS4gRWFjaCBj
b25kaXRpb24gaXMgYSAoY2hhcmFjdGVyaXN0aWMgPT0gdmFsdWUpIG1hdGNoIGFnYWluc3QgYW55IGFjY2Vzc29yeSBpbiB0aGUg
aG9tZS4gKGNyZWF0ZSAvIGNyZWF0ZV90aW1lIGFjdGlvbnMpIn0sInRpbWVfYWZ0ZXIiOnsidHlwZSI6ImFycmF5IiwiaXRlbXMi
OnsidHlwZSI6InN0cmluZyJ9LCJkZXNjcmlwdGlvbiI6IlRpbWUgcHJlZGljYXRlcyBBTkRlZCBpbnRvIHRoZSB0cmlnZ2VyIHNv
IGl0IG9ubHkgZmlyZXMgYWZ0ZXIgdGhlIGdpdmVuIHRpbWUuIFNhbWUgdm9jYWJ1bGFyeSBhcyB0aGUgYHRpbWVgIGZpZWxkOiBc
IkhIOk1NXCIgZm9yIGEgd2FsbC1jbG9jayB0aW1lICh6ZXJvLXBhZGRlZCwgZS5nLiBcIjA3OjAwXCIpIG9yIFwiPHN1bnJpc2V8
c3Vuc2V0PlvCsU5dXCIgd2hlcmUgTiBpcyBtaW51dGVzIChlLmcuLCBcInN1bnNldC0zMFwiLCBcInN1bnJpc2UrMTVcIiwgXCJz
dW5zZXRcIikuIE9mZnNldHMgbGFyZ2VyIHRoYW4gMTQ0MCBtaW51dGVzIGFyZSByZWplY3RlZC4gQ29tYmluZSB3aXRoIHRpbWVf
YmVmb3JlIGZvciBhIHdpbmRvdyAoZS5nLiwgdGltZV9hZnRlcj1bXCIwNzowMFwiXSArIHRpbWVfYmVmb3JlPVtcIjIwOjMwXCJd
IGZvciBcIm9ubHkgZHVyaW5nIHRoZSBkYXlcIiwgb3IgdGltZV9hZnRlcj1bXCJzdW5zZXQtMzBcIl0gKyB0aW1lX2JlZm9yZT1b
XCJzdW5yaXNlKzE1XCJdIGZvciBcImJldHdlZW4gZHVzayBhbmQgZGF3blwiKS4gT24gY3JlYXRlX3RpbWUgdGhlc2UgYXJlIGdh
dGluZyBwcmVkaWNhdGVzIG9uIHRvcCBvZiB0aGUgYHRpbWVgIHRyaWdnZXIgZXZlbnQsIG5vdCB0aGUgdHJpZ2dlciBpdHNlbGYu
IFdoZW4gc2V0IHdpdGhvdXQgZXhwbGljaXQgd2Vla2RheXMsIEhvbWVDbGF3IGF1dG8tZmlsbHMgYWxsIDcgZGF5czsgc2VlIHRo
ZSB3ZWVrZGF5cyBmaWVsZC4gKGNyZWF0ZSAvIGNyZWF0ZV90aW1lIGFjdGlvbnMpIn0sInRpbWVfYmVmb3JlIjp7InR5cGUiOiJh
cnJheSIsIml0ZW1zIjp7InR5cGUiOiJzdHJpbmcifSwiZGVzY3JpcHRpb24iOiJUaW1lIHByZWRpY2F0ZXMgQU5EZWQgaW50byB0
aGUgdHJpZ2dlciBzbyBpdCBvbmx5IGZpcmVzIGJlZm9yZSB0aGUgZ2l2ZW4gdGltZS4gU2FtZSBmb3JtYXQgYW5kIG9mZnNldCBy
dWxlcyBhcyB0aW1lX2FmdGVyLiAoY3JlYXRlIC8gY3JlYXRlX3RpbWUgYWN0aW9ucykifSwiZHVyYXRpb25fc2Vjb25kcyI6eyJ0
eXBlIjoiaW50ZWdlciIsIm1pbmltdW0iOjEsIm1heGltdW0iOjg2NDAwLCJkZXNjcmlwdGlvbiI6IkF1dG8tcmV2ZXJ0IHRoZSB0
cmlnZ2VyJ3MgYWN0aW9ucyBhZnRlciB0aGlzIG1hbnkgc2Vjb25kcyAoMS04NjQwMCwgaS5lLiB1cCB0byAyNCBob3VycykuIElt
cGxlbWVudGVkIGFzIGFuIEhNRHVyYXRpb25FdmVudCBhdHRhY2hlZCB0byB0aGUgdHJpZ2dlcidzIGVuZEV2ZW50cyDigJQgSG9t
ZUtpdCBoYW5kbGVzIHRoZSByZXZlcnQgbmF0aXZlbHksIG5vIGZvbGxvdy11cCBhdXRvbWF0aW9uIHJlcXVpcmVkLiBDb21tb24g
dXNlIGNhc2VzOiBtb3Rpb24tdHJpZ2dlcmVkIGxpZ2h0cyB0aGF0IHNob3VsZCB0dXJuIG9mZiBhZ2FpbiBhZnRlciBhIGRlbGF5
IChlLmcuIGBkdXJhdGlvbl9zZWNvbmRzOiAzMDBgIGZvciBhIDUtbWludXRlIGhvbGQpLCBvciBzdW5zZXQgcG9yY2ggbGlnaHRz
IHRoYXQgc2hvdWxkIHR1cm4gb2ZmIGFmdGVyIGFuIGhvdXIuIChjcmVhdGUgLyBjcmVhdGVfdGltZSBhY3Rpb25zKSJ9LCJjb25k
aXRpb24iOnsidHlwZSI6Im9iamVjdCIsInByb3BlcnRpZXMiOnsiYWNjZXNzb3J5Ijp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlw
dGlvbiI6IkNvbmRpdGlvbiBhY2Nlc3NvcnkgVVVJRCAocHJlZmVycmVkKSBvciBuYW1lIn0sInByb3BlcnR5Ijp7InR5cGUiOiJz
dHJpbmciLCJkZXNjcmlwdGlvbiI6IkNoYXJhY3RlcmlzdGljIG5hbWUgKGUuZy4sIGNvbnRhY3Rfc3RhdGUsIG9jY3VwYW5jeV9k
ZXRlY3RlZCwgcG93ZXIpIn0sImNoYXJhY3RlcmlzdGljIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IkFsaWFzIGZv
ciBcInByb3BlcnR5XCIg4oCUIHByb3ZpZGUgb25lIG9yIHRoZSBvdGhlciJ9LCJ2YWx1ZSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVz
Y3JpcHRpb24iOiJSZXF1aXJlZCB2YWx1ZSBhcyBzdHJpbmcgKGUuZy4sIFwidHJ1ZVwiLCBcIjBcIiwgXCI1MFwiKS4gVXNlcyBl
eGFjdCBtYXRjaCAoPT0pLiJ9LCJyb29tIjp7InR5cGUiOiJzdHJpbmciLCJkZXNjcmlwdGlvbiI6IlJvb20gbmFtZSBmb3IgYWNj
ZXNzb3J5IGRpc2FtYmlndWF0aW9uIHdoZW4gbXVsdGlwbGUgYWNjZXNzb3JpZXMgc2hhcmUgYSBuYW1lIChvcHRpb25hbCkifX0s
InJlcXVpcmVkIjpbImFjY2Vzc29yeSIsInZhbHVlIl0sImFueU9mIjpbeyJyZXF1aXJlZCI6WyJwcm9wZXJ0eSJdfSx7InJlcXVp
cmVkIjpbImNoYXJhY3RlcmlzdGljIl19XSwiZGVzY3JpcHRpb24iOiJTaW5nbGUgY2hhcmFjdGVyaXN0aWMgY29uZGl0aW9uIChv
YmplY3Qg4oCUIG5vdGUgdGhlIHNpbmd1bGFyIGZpZWxkIG5hbWUsIGRpc3RpbmN0IGZyb20gdGhlIHBsdXJhbCBgY29uZGl0aW9u
c2AgYXJyYXkgdXNlZCBieSBjcmVhdGUgLyBjcmVhdGVfdGltZSkgdG8gYXBwZW5kIChBTkRlZCkgdG8gYW4gZXhpc3RpbmcgYXV0
b21hdGlvbidzIHRyaWdnZXIgcHJlZGljYXRlLiBUbyBhZGQgbXVsdGlwbGUgY29uZGl0aW9ucywgY2FsbCBhZGRfY29uZGl0aW9u
IHJlcGVhdGVkbHkg4oCUIGVhY2ggY2FsbCBwcmVzZXJ2ZXMgdGhlIHRyaWdnZXIgVVVJRCwgc28gcGh5c2ljYWwgYnV0dG9uIGJp
bmRpbmdzLCBTaXJpIHJlZmVyZW5jZXMsIGFuZCBvdGhlciBVVUlELWtleWVkIGludGVncmF0aW9ucyBzdXJ2aXZlIGV2ZXJ5IG1v
ZGlmaWNhdGlvbi4gVGhlIHJlYWQtc2lkZSBkZWNvZGVyIChsaXN0L2dldCkgc3VyZmFjZXMgdGhlIG5ldyBjb25kaXRpb24gYXV0
b21hdGljYWxseS4gVG8gcmVwbGFjZSBhbiBleGlzdGluZyBjb25kaXRpb24gc2V0LCBkZWxldGUgdGhlIGF1dG9tYXRpb24gYW5k
IHJlY3JlYXRlIGl0LiAoYWRkX2NvbmRpdGlvbiBhY3Rpb24pIn0sImRyeV9ydW4iOnsidHlwZSI6ImJvb2xlYW4iLCJkZXNjcmlw
dGlvbiI6IlByZXZpZXcgY2hhbmdlcyB3aXRob3V0IGFwcGx5aW5nIChjcmVhdGUvY3JlYXRlX3RpbWUvZGVsZXRlL2FkZF9jb25k
aXRpb24gYWN0aW9ucykifX0sInJlcXVpcmVkIjpbImFjdGlvbiJdfX0seyJuYW1lIjoiaG9tZWtpdF93ZWJob29rIiwiZGVzY3Jp
cHRpb24iOiJNYW5hZ2Ugd2ViaG9vayBjb25maWd1cmF0aW9uIGZvciBwdXNoaW5nIEhvbWVLaXQgZXZlbnRzIHRvIE9wZW5DbGF3
IG9yIG90aGVyIHNlcnZpY2VzLiBBY3Rpb25zOiBzZXR1cCAoY29uZmlndXJlIFVSTCwgdG9rZW4sIGFuZCBlbmFibGUgaW4gb25l
IHN0ZXApLCB0ZXN0IChzZW5kIGEgdGVzdCBldmVudCBhbmQgc2hvdyB0aGUgSFRUUCByZXNwb25zZSksIHJlc2V0IChyZXNldCB0
aGUgY2lyY3VpdCBicmVha2VyKSwgc3RhdHVzIChzaG93IHdlYmhvb2sgaGVhbHRoIGFuZCBkZWxpdmVyeSBzdGF0cykuIiwiaW5w
dXRTY2hlbWEiOnsidHlwZSI6Im9iamVjdCIsInByb3BlcnRpZXMiOnsiYWN0aW9uIjp7InR5cGUiOiJzdHJpbmciLCJlbnVtIjpb
InNldHVwIiwidGVzdCIsInJlc2V0Iiwic3RhdHVzIl0sImRlc2NyaXB0aW9uIjoiQWN0aW9uIHRvIHBlcmZvcm0uIERlZmF1bHQ6
IHN0YXR1cyJ9LCJ1cmwiOnsidHlwZSI6InN0cmluZyIsImRlc2NyaXB0aW9uIjoiQmFzZSBnYXRld2F5IFVSTCwgZS5nLiBodHRw
Oi8vMTI3LjAuMC4xOjE4Nzg5IChzZXR1cCBhY3Rpb24pLiBIb21lQ2xhdyBhcHBlbmRzIC9ob29rcy93YWtlIGF1dG9tYXRpY2Fs
bHkg4oCUIGRvIE5PVCBpbmNsdWRlIHRoZSBwYXRoLiJ9LCJ0b2tlbiI6eyJ0eXBlIjoic3RyaW5nIiwiZGVzY3JpcHRpb24iOiJC
ZWFyZXIgdG9rZW4gZm9yIHdlYmhvb2sgYXV0aGVudGljYXRpb24gKHNldHVwIGFjdGlvbikifSwiZW5hYmxlZCI6eyJ0eXBlIjoi
Ym9vbGVhbiIsImRlc2NyaXB0aW9uIjoiRW5hYmxlIG9yIGRpc2FibGUgdGhlIHdlYmhvb2sgKHNldHVwIGFjdGlvbikuIERlZmF1
bHQ6IHRydWUifX19fSx7Im5hbWUiOiJob21la2l0X2V2ZW50cyIsImRlc2NyaXB0aW9uIjoiR2V0IHJlY2VudCBIb21lS2l0IGV2
ZW50cyDigJQgY2hhcmFjdGVyaXN0aWMgY2hhbmdlcywgc2NlbmUgdHJpZ2dlcnMsIGFuZCBhY2Nlc3NvcnkgY29udHJvbCBhY3Rp
b25zLiBVc2UgdG8gdW5kZXJzdGFuZCB3aGF0IGhhcHBlbmVkIHJlY2VudGx5IGluIHRoZSBob21lLiIsImlucHV0U2NoZW1hIjp7
InR5cGUiOiJvYmplY3QiLCJwcm9wZXJ0aWVzIjp7ImxpbWl0Ijp7InR5cGUiOiJudW1iZXIiLCJkZXNjcmlwdGlvbiI6Ik1heGlt
dW0gbnVtYmVyIG9mIGV2ZW50cyB0byByZXR1cm4gKGRlZmF1bHQ6IDUwKSJ9LCJzaW5jZSI6eyJ0eXBlIjoic3RyaW5nIiwiZGVz
Y3JpcHRpb24iOiJJU08gODYwMSB0aW1lc3RhbXAg4oCUIG9ubHkgcmV0dXJuIGV2ZW50cyBhZnRlciB0aGlzIHRpbWUifSwidHlw
ZSI6eyJ0eXBlIjoic3RyaW5nIiwiZW51bSI6WyJjaGFyYWN0ZXJpc3RpY19jaGFuZ2UiLCJob21lc191cGRhdGVkIiwic2NlbmVf
dHJpZ2dlcmVkIiwiYWNjZXNzb3J5X2NvbnRyb2xsZWQiXSwiZGVzY3JpcHRpb24iOiJGaWx0ZXIgYnkgZXZlbnQgdHlwZSJ9fX19
XQ==
"""
        return Data(base64Encoded: encoded.filter { !$0.isWhitespace }) ?? Data("[]".utf8)
    }()

    static var allToolNames: [String] {
        ((try? JSONSerialization.jsonObject(with: allToolsJSON) as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
    }

    @MainActor static func call(name: String, arguments: Data) async -> Data {
        guard allToolNames.contains(name) else { return error("Unknown tool: \(name)") }
        guard let args = (try? JSONSerialization.jsonObject(with: arguments)) as? [String: Any] else {
            return error("Invalid arguments")
        }
        guard validateArguments(args, tool: name) else { return error("Invalid arguments") }

        do {
            let result: Any = try await { () async throws -> Any in
                let hk = HomeKitManager.shared
                switch name {
                case "homekit_status":
                    return ["ready": hk.isReady, "homes": hk.homeCount, "accessories": hk.totalAccessoryCount]
                case "homekit_accessories":
                    switch string(args, "action") ?? "list" {
                    case "list": return try await hk.listAccessories(homeID: string(args, "home_id"), room: string(args, "room"))
                    case "get":
                        guard let id = string(args, "accessory_id") else { throw HomeKitManager.ControlError.invalidArgument("accessory_id is required") }
                        guard let value = try await hk.getAccessory(id: id, homeID: string(args, "home_id"), refresh: !bool(args, "no_refresh")) else { throw HomeKitManager.ControlError.accessoryNotFound(id) }
                        return value
                    case "search":
                        guard let query = string(args, "query") else { throw HomeKitManager.ControlError.invalidArgument("query is required") }
                        return await hk.searchAccessories(query: query, category: string(args, "category"), homeID: string(args, "home_id"))
                    case "control":
                        guard let id = string(args, "accessory_id"), let characteristic = string(args, "characteristic"), let value = string(args, "value") else { throw HomeKitManager.ControlError.invalidArgument("accessory_id, characteristic, and value are required") }
                        return try await hk.controlAccessory(id: id, characteristic: characteristic, value: value, homeID: string(args, "home_id"), serviceType: string(args, "service_type"), serviceName: string(args, "service_name"), serviceID: string(args, "service_id"), serviceIndex: int(args, "service_index"), dryRun: bool(args, "dry_run"), verify: args["verify"] as? Bool ?? true)
                    default: throw HomeKitManager.ControlError.invalidArgument("unknown accessories action")
                    }
                case "homekit_rooms": return await hk.listRooms(homeID: string(args, "home_id"))
                case "homekit_scenes":
                    switch string(args, "action") ?? "list" {
                    case "list": return await hk.listScenes(homeID: string(args, "home_id"))
                    case "get": guard let id = string(args, "scene_id") else { throw HomeKitManager.ControlError.invalidArgument("scene_id is required") }; return try await hk.getScene(id: id, homeID: string(args, "home_id"))
                    case "trigger": guard let id = string(args, "scene_id") else { throw HomeKitManager.ControlError.invalidArgument("scene_id is required") }; return try await hk.triggerScene(id: id, homeID: string(args, "home_id"))
                    default: throw HomeKitManager.ControlError.invalidArgument("unknown scenes action")
                    }
                case "homekit_device_map": return await hk.deviceMap(homeID: string(args, "home_id"))
                case "homekit_manage": return try await manage(args, hk: hk)
                case "homekit_config":
                    switch string(args, "action") ?? "get" {
                    case "get": return HomeClawConfig.shared.toDict()
                    case "set":
                        if let home = string(args, "default_home_id") { HomeClawConfig.shared.defaultHomeID = home.isEmpty || home.lowercased() == "none" ? nil : home }
                        if let mode = string(args, "accessory_filter_mode") { HomeClawConfig.shared.filterMode = mode }
                        if let ids = args["allowed_accessory_ids"] as? [String] { HomeClawConfig.shared.setAllowedAccessories(ids) }
                        return HomeClawConfig.shared.toDict()
                    default: throw HomeKitManager.ControlError.invalidArgument("unknown config action")
                    }
                case "homekit_events":
                    let since = (string(args, "since")).flatMap { ISO8601DateFormatter().date(from: $0) }
                    let type = string(args, "type").flatMap(HomeEventLogger.EventType.init(rawValue:))
                    return ["events": HomeEventLogger.shared.readEvents(since: since, limit: int(args, "limit") ?? 50, type: type)]
                case "homekit_webhook": return try await webhook(args)
                case "homekit_automations": return try await automations(args, hk: hk)
                default: throw HomeKitManager.ControlError.invalidArgument("unsupported tool")
                }
            }()
            return json(result)
        } catch {
            return Self.error(error.localizedDescription)
        }
    }

    private static func validateArguments(_ args: [String: Any], tool: String) -> Bool {
        let integerKeys = ["press_type", "service_index", "limit", "duration_seconds"]
        for key in integerKeys where args[key] != nil {
            guard let number = args[key] as? NSNumber, String(cString: number.objCType) != "c", String(cString: number.objCType) != "C", number.doubleValue.rounded() == number.doubleValue else { return false }
        }
        if let press = args["press_type"] as? NSNumber, !(0...2).contains(press.intValue) { return false }
        if let index = args["service_index"] as? NSNumber, index.intValue < 1 { return false }
        if let limit = args["limit"] as? NSNumber, !(1...1000).contains(limit.intValue) { return false }
        if let duration = args["duration_seconds"] as? NSNumber, !(1...86400).contains(duration.intValue) { return false }
        for key in ["dry_run", "verify", "no_refresh", "enabled"] where args[key] != nil { guard args[key] is Bool else { return false } }
        for key in ["home_id", "accessory_id", "room", "query", "category", "characteristic", "value", "service_type", "service_name", "service_id", "scene_id", "id", "name", "new_name", "time", "since", "type", "action"] where args[key] != nil { guard args[key] is String else { return false } }
        for key in ["actions", "conditions", "assignments"] where args[key] != nil { guard args[key] is [[String: Any]] || args[key] is [[String: String]] else { return false } }
        for key in ["weekdays", "time_after", "time_before"] where args[key] != nil { guard let values = args[key] as? [Any] else { return false }; if key == "weekdays" { guard values.allSatisfy({ ($0 as? NSNumber).map { String(cString: $0.objCType) != "c" && $0.doubleValue.rounded() == $0.doubleValue && (1...7).contains($0.intValue) } == true }) else { return false } } else { guard values.allSatisfy({ $0 is String }) else { return false } } }
        _ = tool
        return true
    }
    private static func string(_ args: [String: Any], _ key: String) -> String? { args[key] as? String }
    private static func int(_ args: [String: Any], _ key: String) -> Int? {
        if let value = args[key] as? Int { return value }
        guard let number = args[key] as? NSNumber, String(cString: number.objCType) != "c", String(cString: number.objCType) != "C", number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue, number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max) else { return nil }
        return Int(exactly: number.int64Value)
    }
    private static func bool(_ args: [String: Any], _ key: String) -> Bool { args[key] as? Bool ?? false }
    private static func json(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8) }
    private static func error(_ message: String) -> Data { json(["error": message]) }

    @MainActor private static func manage(_ args: [String: Any], hk: HomeKitManager) async throws -> Any {
        guard let action = string(args, "action") else { throw HomeKitManager.ControlError.invalidArgument("action is required") }
        let home = string(args, "home_id"), id = string(args, "id"), dry = bool(args, "dry_run")
        switch action {
        case "rename": guard let id, let name = string(args, "new_name") else { throw HomeKitManager.ControlError.invalidArgument("id and new_name are required") }; return try await hk.renameAccessory(id: id, newName: name, homeID: home, dryRun: dry)
        case "remove_accessory": guard let id else { throw HomeKitManager.ControlError.invalidArgument("id is required") }; return try await hk.removeAccessory(id: id, homeID: home, dryRun: dry)
        case "assign_rooms": guard let assignments = args["assignments"] as? [[String: String]] else { throw HomeKitManager.ControlError.invalidArgument("assignments is required") }; return try await hk.assignRooms(homeName: home, assignments: assignments, dryRun: dry)
        case "create_room": guard let name = string(args, "name") else { throw HomeKitManager.ControlError.invalidArgument("name is required") }; return try await hk.createRoom(name: name, homeID: home, dryRun: dry)
        case "rename_room": guard let id, let name = string(args, "new_name") else { throw HomeKitManager.ControlError.invalidArgument("id and new_name are required") }; return try await hk.renameRoom(roomID: id, newName: name, homeID: home, dryRun: dry)
        case "remove_room": guard let id else { throw HomeKitManager.ControlError.invalidArgument("id is required") }; return try await hk.removeRoom(roomID: id, homeID: home, dryRun: dry)
        case "create_zone": guard let name = string(args, "name") else { throw HomeKitManager.ControlError.invalidArgument("name is required") }; return try await hk.createZone(name: name, homeID: home, dryRun: dry)
        case "remove_zone": guard let id else { throw HomeKitManager.ControlError.invalidArgument("id is required") }; return try await hk.removeZone(zoneID: id, homeID: home, dryRun: dry)
        case "add_room_to_zone": guard let room = string(args, "room"), let zone = string(args, "zone") else { throw HomeKitManager.ControlError.invalidArgument("room and zone are required") }; return try await hk.addRoomToZone(roomID: room, zoneID: zone, homeID: home, dryRun: dry)
        case "remove_room_from_zone": guard let room = string(args, "room"), let zone = string(args, "zone") else { throw HomeKitManager.ControlError.invalidArgument("room and zone are required") }; return try await hk.removeRoomFromZone(roomID: room, zoneID: zone, homeID: home, dryRun: dry)
        default: throw HomeKitManager.ControlError.invalidArgument("unknown manage action")
        }
    }

    @MainActor private static func automations(_ args: [String: Any], hk: HomeKitManager) async throws -> Any {
        let action = string(args, "action") ?? "list"
        let home = string(args, "home_id"), dry = bool(args, "dry_run")
        switch action {
        case "list": return await hk.listAutomations(homeID: home)
        case "get": guard let id = string(args, "id") else { throw HomeKitManager.ControlError.invalidArgument("id is required") }; return try await hk.getAutomation(id: id, homeID: home)
        case "delete": guard let id = string(args, "id") else { throw HomeKitManager.ControlError.invalidArgument("id is required") }; return try await hk.deleteAutomation(id: id, homeID: home, dryRun: dry)
        case "enable", "disable": guard let id = string(args, "id") else { throw HomeKitManager.ControlError.invalidArgument("id is required") }; return try await hk.enableAutomation(id: id, enabled: action == "enable", homeID: home)
        case "add_condition":
            guard let id = string(args, "id"), let condition = args["condition"] as? [String: Any], let accessory = condition["accessory"] as? String, let value = condition["value"] as? String, let property = (condition["property"] as? String) ?? (condition["characteristic"] as? String) else { throw HomeKitManager.ControlError.invalidArgument("id and condition accessory/property/value are required") }
            return try await hk.addAutomationCondition(id: id, accessoryID: accessory, conditionRoom: condition["room"] as? String, property: property, value: value, homeID: home, dryRun: dry)
        case "create", "create_time":
            guard let name = string(args, "name") else { throw HomeKitManager.ControlError.invalidArgument("name is required") }
            let actions = args["actions"] as? [[String: String]], conditions = args["conditions"] as? [[String: String]] ?? []
            let weekdays = (args["weekdays"] as? [Int]) ?? [], timeConditions = try parseTimeConditions(args)
            if action == "create_time" {
                guard let time = string(args, "time") else { throw HomeKitManager.ControlError.invalidArgument("time is required") }
                return try await hk.createTimeAutomation(name: name, time: time, weekdays: weekdays, conditions: conditions, timeConditions: timeConditions, durationSeconds: int(args, "duration_seconds"), sceneID: string(args, "scene_id"), actions: actions, homeID: home, dryRun: dry)
            }
            guard let accessory = string(args, "accessory_id") else { throw HomeKitManager.ControlError.invalidArgument("accessory_id is required") }
            return try await hk.createAutomation(name: name, accessoryID: accessory, pressType: int(args, "press_type") ?? 0, characteristic: string(args, "characteristic"), triggerValue: string(args, "trigger_value"), sceneID: string(args, "scene_id"), actions: actions, serviceIndex: int(args, "service_index"), weekdays: weekdays, conditions: conditions, timeConditions: timeConditions, durationSeconds: int(args, "duration_seconds"), homeID: home, dryRun: dry)
        default: throw HomeKitManager.ControlError.invalidArgument("unknown automations action")
        }
    }

    private static func parseTimeConditions(_ args: [String: Any]) throws -> [TimeCondition] {
        var result: [TimeCondition] = []
        for (key, relation) in [("time_after", TimeCondition.Relation.after), ("time_before", TimeCondition.Relation.before)] {
            for raw in (args[key] as? [String]) ?? [] {
                guard let condition = TimeCondition.parse(raw, relation: relation) else { throw HomeKitManager.ControlError.invalidArgument("invalid time condition: \(raw)") }
                result.append(condition)
            }
        }
        return result
    }

    @MainActor private static func webhook(_ args: [String: Any]) async throws -> Any {
        switch string(args, "action") ?? "status" {
        case "status": return HomeClawConfig.shared.toDict()["webhook"] ?? ["enabled": false]
        case "reset": WebhookCircuitBreaker.shared.manualReset(); return ["reset": true]
        case "setup":
            guard let url = string(args, "url"), let token = string(args, "token") else { throw HomeKitManager.ControlError.invalidArgument("url and token are required") }
            HomeClawConfig.shared.webhookConfig = HomeClawConfig.WebhookConfig(enabled: args["enabled"] as? Bool ?? true, url: url, token: token, events: nil, webhookEndpoint: "/hooks/homeclaw")
            return HomeClawConfig.shared.toDict()["webhook"] ?? [:]
        case "test": return HomeEventLogger.shared.testWebhook()
        default: throw HomeKitManager.ControlError.invalidArgument("unknown webhook action")
        }
    }
}
