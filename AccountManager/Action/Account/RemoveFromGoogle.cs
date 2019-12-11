using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.Account
{
    public class RemoveFromGoogle : AccountAction
    {
        public RemoveFromGoogle() : base(
            "Verwijder Google Account",
            "Dit account bestaat enkel bij Google. Waarschijnlijk mag dit verwijderd worden.",
            true)
        {
        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await AccountApi.Google.AccountManager.Delete(linkedAccount?.Google.Account.Mail).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (account.Wisa.Exists && account.Directory.Exists && account.Smartschool.Exists || !account.Google.Exists)
            {
                account.Actions.Add(new RemoveFromGoogle());
            }
        }
    }
}
