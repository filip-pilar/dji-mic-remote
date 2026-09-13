import Foundation

@main
struct MappingChecks {
    static func main() {
        let header = "RegistryID  Key                   Value\n"
        assert(receiverMappingsAreEmpty(header + "10006b1f3   UserKeyMapping   (null)\n") == true)
        assert(receiverMappingsAreEmpty(header + "10006b1f3   UserKeyMapping   (\n)\n") == true)
        assert(receiverMappingsAreEmpty(header + "123 UserKeyMapping []\n") == true)
        assert(receiverMappingsAreEmpty("") == nil)
        assert(receiverMappingsAreEmpty(header) == nil)
        assert(receiverMappingsAreEmpty("permission denied") == nil)
        let occupied = "456 UserKeyMapping (\n{ HIDKeyboardModifierMappingSrc = 51539607785; HIDKeyboardModifierMappingDst = 30064771187; }\n)\n"
        assert(receiverMappingsAreEmpty(header + occupied) == false)
        assert(receiverMappingsAreEmpty(header + "123 UserKeyMapping (null)\n" + occupied) == false)
        assert(receiverMappingsAreEmpty(header + "123 UserKeyMapping (\n") == false)
        print("Passed 9 mapping parser regression checks")
    }
}
