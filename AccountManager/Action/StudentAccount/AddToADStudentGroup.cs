using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action.StudentAccount
{
    class AddToADStudentGroup : AccountAction
    {
        public AddToADStudentGroup() : base(
            "Voeg de leerling toe aan de AD groep Students",
            "Wanneer de leerling geen lid is van deze group, is de toegang van het account beperkt.",
            true, true)
        {

        }

        public async override Task Apply(State.Linked.LinkedAccount linkedAccount, DateTime deletionDate)
        {
            await linkedAccount.Directory.Account.AddToGroup("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Leerlingen,OU=ArcadiaGroups,DC=arcadiascholen,DC=be").ConfigureAwait(false);
        }

        public static void Evaluate(State.Linked.LinkedAccount account)
        {
            if (!account.Directory.Account.Groups.Contains("CN=" + State.App.Instance.Settings.SchoolPrefix.Value + "-Leerlingen,OU=ArcadiaGroups,DC=arcadiascholen,DC=be"))
            {
                account.Directory.FlagWarning();
                account.Actions.Add(new AddToADStudentGroup());
                account.OK = false;
            }
        }
    }
}
