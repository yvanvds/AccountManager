using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class AddToADClassGroup : AccountAction
    {
        public AddToADClassGroup() : base(
            "Voeg de leerling toe aan zijn clasgroep in AD",
            "Wanneer de leerling geen lid is van zijn klasgroep, dan wordt het account niet toegevoegd aan zijn klas teams",
            true,
            true
        )
        { }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            // remove from existing classes
            var regex = new Regex("/" + State.App.Instance.Settings.SchoolPrefix.Value + "-+[1-7]");
            List<string> results = linkedAccount.Directory.Account.Groups.Where(f => regex.IsMatch(f)).ToList();

            foreach(var group in results)
            {
                await linkedAccount.Directory.Account.RemoveFromGroup(group).ConfigureAwait(false);
            }
            await linkedAccount.Directory.Account.AddToGroup("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-" + linkedAccount.Directory.Account.ClassGroup + "," + State.App.Instance.AD.ClassesRoot.Value).ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            string target = "CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-" + account.Directory.Account.ClassGroup + "," + State.App.Instance.AD.ClassesRoot.Value;
            if (!account.Directory.Account.Groups.Any(s => s.Equals(target, StringComparison.OrdinalIgnoreCase)))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new AddToADClassGroup());
                account.OK = false;
            }
        }
    }
}
