using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class UnregisterSmartschool : AccountAction
    {
        public UnregisterSmartschool() : base(
            "Schrijf de leerling uit in smartschool",
            "De leerling wordt uitgeschreven zonder het account te verwijderen", true)
        { }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Smartschool.AccountManager.UnregisterStudent(linkedAccount.Smartschool.Account, deletionDate).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Wisa.Exists && account.Smartschool.Exists && account.Smartschool.Account.Status == "actief")
            {
                account.Actions.Add(new UnregisterSmartschool());
            }
        }
    }
}
