using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class RemoveFromSmartschool : AccountAction
    {
        public RemoveFromSmartschool() : base(
            "Verwijder Smartschool Account",
            "Dit account bestaat niet in Azure en niet in Wisa. Waarschijnlijk mag het verwijderd worden.",
            true
        )
        { }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            await AccountApi.Smartschool.AccountManager.Delete(account.Smartschool.Account).ConfigureAwait(false);

        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (!account.Wisa.Exists && !account.Azure.Exists && account.Smartschool.Exists)
            {
                account.Actions.Add(new RemoveFromSmartschool());
            }
        }
    }
}
