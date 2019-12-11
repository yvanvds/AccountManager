using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Account
{
    class RemoveFromDirectoryAndSmartschool : AccountAction
    {
        public RemoveFromDirectoryAndSmartschool() : base(
            "Verwijder dit account",
            "Accounts die niet bestaan in Wisa zijn overbodig",
            true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Directory.AccountManager.DeleteStudent(linkedAccount.Directory.Account).ConfigureAwait(false);
            await AccountApi.Smartschool.AccountManager.UnregisterStudent(linkedAccount.Smartschool.Account, deletionDate).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Wisa.Exists && account.Directory.Exists && account.Smartschool.Exists)
            {
                account.Actions.Add(new RemoveFromDirectoryAndSmartschool());
            }
        }
    }
}
