using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class DeleteFromSmartschool : AccountAction
    {
        public DeleteFromSmartschool(bool allreadyDisabled) : base(
            "Verwijder dit account uit smartschool",
            "Accounts die niet bestaan in Wisa zijn overbodig." + (allreadyDisabled ? " (Account is al uitgeschakeld)" : ""), true)
        { }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Smartschool.AccountManager.Delete(linkedAccount.Smartschool.Account, deletionDate).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Wisa.Exists && account.Smartschool.Exists)
            {
                account.Actions.Add(new DeleteFromSmartschool(account.Smartschool.Account.Status != "actief"));
            }
        }
    }
}
