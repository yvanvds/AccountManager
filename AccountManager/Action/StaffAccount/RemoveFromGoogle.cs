using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class RemoveFromGoogle : AccountAction
    {
        public RemoveFromGoogle() : base(
            "Verwijder Google Account",
            "Dit account bestaat niet in Wisa. Waarschijnlijk mag dit verwijderd worden, tenzij het een nieuw personeelslid betreft dat nog niet aan Wisa toegevoegd werd.",
            true)
        {
        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {

            await AccountApi.Google.AccountManager.Delete(account?.Google.Account.Mail).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (!account.Wisa.Exists && account.Google.Exists)
            {
                account.Actions.Add(new RemoveFromGoogle());
            }
        }
    }
}
