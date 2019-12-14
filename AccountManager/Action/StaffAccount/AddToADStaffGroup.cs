using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class AddToADStaffGroup : AccountAction
    {
        public AddToADStaffGroup() : base(
            "Toevoegen aan groep Teachers",
            "Wanneer dit account geen lid is van deze group, is de toegang van het account beperkt.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            // TODO: should not be bound to school
            if (account.Directory.Account.Role == AccountApi.AccountRole.Teacher)
            {
                await account.Directory.Account.AddToGroup("CN=Teachers,OU=Security Groups,DC=sanctamaria-aarschot,DC=be").ConfigureAwait(false);
            }
            if (account.Directory.Account.Role == AccountApi.AccountRole.Support)
            {
                await account.Directory.Account.AddToGroup("CN=Support,OU=Security Groups,DC=sanctamaria-aarschot,DC=be").ConfigureAwait(false);
            }
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (account.Directory.Account.Role == AccountApi.AccountRole.Teacher 
                && !account.Directory.Account.Groups.Contains("CN=Teachers,OU=Security Groups,DC=sanctamaria-aarschot,DC=be"))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new AddToADStaffGroup());
                account.OK = false;
            }

            if (account.Directory.Account.Role == AccountApi.AccountRole.Support
                && !account.Directory.Account.Groups.Contains("CN=Support,OU=Security Groups,DC=sanctamaria-aarschot,DC=be"))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new AddToADStaffGroup());
                account.OK = false;
            }
        }
    }
}
