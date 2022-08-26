using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StaffAccount
{
    class RemoveFromDirectory : AccountAction
    {
        public RemoveFromDirectory() : base(
            "Verwijder Active Directory Account",
            "Dit account bestaat niet in Wisa. Waarschijnlijk mag dit verwijderd worden, tenzij het een nieuw personeelslid betreft dat nog niet aan Wisa toegevoegd werd.",
            true)
        {

        }

        public async override Task Apply(State.Linked.LinkedStaffMember account)
        {
            bool connected = await State.App.Instance.AD.Connect().ConfigureAwait(false);
            if (!connected) return;

            await AccountApi.Directory.AccountManager.DeleteStaff(account.Directory.Account).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedStaffMember account)
        {
            if (!account.Wisa.Exists && account.Directory.Exists)
            {
                account.Actions.Add(new RemoveFromDirectory());
            }
        }
    }
}
