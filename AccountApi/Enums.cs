using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi
{
    public enum GenderType
    {
        Male,
        Female,
        Transgender,
    }

    public enum AccountRole
    {
        Other, // use this role if you do not want to add this account to smartschool
        Student,
        Teacher,
        Support,
        Director,
        IT,
    }

    public enum AccountType // for smartschool
    {
        Student = 0,
        CoAccount1 = 1,
        CoAccount2 = 2,
        CoAccount3 = 3,
        CoAccount4 = 4,
        CoAccount5 = 5,
        CoAccount6 = 6,
    }

    public enum AccountState
    {
        Invalid,
        Active,
        Inactive,
        Administrative,
    }

    public enum GroupType
    {
        Invalid,
        Group,
        Class,
    }

    public enum ConfigState
    {
        Unknown,
        InProgress,
        OK,
        Failed,
    }

    public enum Origin
    {
        All,
        Wisa,
        Smartschool,
        Directory,
        Google,
        Other,
    }

    public enum Rule
    {
        // Smartschool Import Rules
        SS_DiscardGroup,
        SS_NoSubGroups,

        // Wisa Import Rules
        WI_ReplaceInstitution,
        WI_DontImportClass,
    }

    public enum RuleType
    {
        SS_Import,
        WISA_Import,
    }

    public enum RuleAction
    {
        Discard,
        Modify,
    }
}
